import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle
import SQLKit

/// Durable, resumable write-behind embedding for final user-facing model
/// answers. One job is claimed atomically so multiple replicas are safe.
actor MemoryIndexWorker: Service {
    let fluent: Fluent
    let embeddings: any EmbeddingService
    let logger: Logger
    let tickInterval: Duration

    init(
        fluent: Fluent,
        embeddings: any EmbeddingService,
        logger: Logger = Logger(label: "lv.memory.index.worker"),
        tickInterval: Duration = .seconds(2)
    ) {
        self.fluent = fluent
        self.embeddings = embeddings
        self.logger = logger
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("memory.index.worker started")
        while !Task.isCancelled {
            do {
                if try await tick() == 0 {
                    try await Task.sleep(for: tickInterval)
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning("memory.index.worker tick failed: \(error)")
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    @discardableResult
    func tick() async throws -> Int {
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }
        guard let job = try await sql.raw("""
        WITH candidate AS (
            SELECT id FROM memory_index_jobs
            WHERE status IN ('pending', 'retry') AND next_attempt_at <= NOW()
            ORDER BY created_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        UPDATE memory_index_jobs j
        SET status = 'processing', attempts = attempts + 1, updated_at = NOW()
        FROM candidate
        WHERE j.id = candidate.id
        RETURNING j.id, j.tenant_id, j.source_kind, j.source_id,
                  j.conversation_message_id, j.content, j.provider, j.model, j.attempts
        """).first(decoding: MemoryIndexJobRow.self) else { return 0 }

        do {
            if try await existingMemory(sql: sql, job: job) == nil {
                let content = String(job.content.prefix(12_000))
                let vector = try await embeddings.embed(content, tenantID: job.tenant_id)
                _ = try await MemoryRepository(fluent: fluent).create(
                    tenantID: job.tenant_id,
                    content: content,
                    embedding: vector,
                    tags: ["model-output"],
                    reviewState: MemoryReviewState.auto,
                    contribution: .model(
                        .create,
                        source: MemorySourceKindDTO(rawValue: job.source_kind) ?? .chat,
                        provider: job.provider,
                        model: job.model,
                        reference: job.source_id
                    ),
                    originConversationMessageID: job.conversation_message_id
                )
            }
            try await sql.raw("""
            UPDATE memory_index_jobs
            SET status = 'completed', last_error = NULL, updated_at = NOW()
            WHERE id = \(bind: job.id)
            """).run()
        } catch {
            let delaySeconds = min(3600, 1 << min(job.attempts, 10))
            let message = String(String(describing: error).prefix(500))
            try await sql.raw("""
            UPDATE memory_index_jobs
            SET status = 'retry', last_error = \(bind: message),
                next_attempt_at = NOW() + (\(bind: delaySeconds) * INTERVAL '1 second'),
                updated_at = NOW()
            WHERE id = \(bind: job.id)
            """).run()
            logger.warning("memory output indexing deferred", metadata: [
                "job_id": .string(job.id.uuidString),
                "attempt": .stringConvertible(job.attempts),
            ])
        }
        return 1
    }

    private func existingMemory(sql: any SQLDatabase, job: MemoryIndexJobRow) async throws -> UUID? {
        struct Row: Decodable { let id: UUID }
        return try await sql.raw("""
        SELECT id FROM memories
        WHERE tenant_id = \(bind: job.tenant_id)
          AND origin_kind = \(bind: job.source_kind)
          AND origin_source_id = \(bind: job.source_id)
        LIMIT 1
        """).first(decoding: Row.self)?.id
    }
}

private struct MemoryIndexJobRow: Decodable {
    let id: UUID
    let tenant_id: UUID
    let source_kind: String
    let source_id: String
    let conversation_message_id: UUID?
    let content: String
    let provider: String?
    let model: String?
    let attempts: Int
}
