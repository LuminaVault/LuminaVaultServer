import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// Per-tenant backfill outcome. The admin endpoint returns these.
struct ChunkBackfillResult: Codable, Sendable {
    let tenantID: UUID
    /// Memories examined in this pass.
    let scanned: Int
    /// Memories that gained chunk rows.
    let indexed: Int
    /// Chunk rows written across all indexed memories.
    let chunks: Int
    /// Memories skipped because they already had chunks.
    let alreadyIndexed: Int
    /// Memories that could not be chunked (source file unreadable, embedding
    /// provider error). Left for the next run to retry.
    let failed: Int
}

/// Backfills `memory_chunks` for memories that predate chunking.
///
/// Every existing memory was embedded as one whole-document vector and has no
/// chunk rows, so until this runs their hits carry no citation. The document
/// arm of `HybridMemorySearch` keeps them retrievable in the meantime — this
/// service upgrades them rather than rescuing them.
///
/// Design constraints, in order of importance:
///
/// 1. **Idempotent.** A memory that already has chunks is skipped. Re-running
///    after a crash costs a cheap existence check per memory, not a re-embed.
/// 2. **Resumable.** Work is claimed in bounded batches ordered by memory id,
///    so an interrupted run resumes where it stopped with no cursor to persist.
/// 3. **Non-destructive.** Nothing is deleted or rewritten outside
///    `memory_chunks`. The source vault file is opened read-only; the
///    `memories` row is never touched.
/// 4. **Bounded.** `batchSize` caps memories per call so an admin trigger
///    cannot pin the embedding provider for an hour in one request.
struct ChunkBackfillService: Sendable {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let indexer: DocumentChunkIndexer
    let logger: Logger

    /// Memories processed per invocation. Each one costs N embedding calls, so
    /// this is deliberately small — call it repeatedly rather than raising it.
    static let defaultBatchSize = 50

    /// Backfill one tenant's un-chunked memories.
    ///
    /// Prefers the raw vault file as the chunking source: it has the real line
    /// numbers a citation points at. Falls back to `memories.content` when the
    /// memory has no source file (direct upserts, chat-derived memories) — the
    /// citation then carries a heading trail and line range within the memory
    /// text itself, which is still checkable, just not against a file.
    @discardableResult
    func backfill(
        tenantID: UUID,
        batchSize: Int = defaultBatchSize
    ) async throws -> ChunkBackfillResult {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for chunk backfill")
        }
        let limit = max(1, min(batchSize, 500))

        // LEFT JOIN ... IS NULL is the idempotency check and the work queue in
        // one statement: only memories with zero chunk rows come back.
        let rows = try await sql.raw("""
        SELECT m.id AS memory_id,
               m.content AS content,
               m.space_id AS space_id,
               m.source_vault_file_id AS vault_file_id,
               v.path AS source_path
        FROM memories m
        LEFT JOIN vault_files v
            ON v.id = m.source_vault_file_id
           AND v.tenant_id = m.tenant_id
        LEFT JOIN memory_chunks c
            ON c.memory_id = m.id
           AND c.tenant_id = m.tenant_id
        WHERE m.tenant_id = \(bind: tenantID)
          AND c.chunk_id IS NULL
          AND m.review_state <> \(bind: "rejected")
        ORDER BY m.id
        LIMIT \(bind: limit)
        """).all(decoding: BackfillCandidateRow.self)

        var indexed = 0
        var chunks = 0
        var failed = 0

        for row in rows {
            let source = readSource(tenantID: tenantID, path: row.source_path) ?? row.content
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                let written = try await indexer.index(
                    tenantID: tenantID,
                    memoryID: row.memory_id,
                    vaultFileID: row.vault_file_id,
                    spaceID: row.space_id,
                    sourcePath: row.source_path,
                    content: source
                )
                if written > 0 {
                    indexed += 1
                    chunks += written
                }
            } catch {
                // Left un-chunked deliberately: the next run picks it up again
                // because the LEFT JOIN still finds no chunk rows for it.
                failed += 1
                logger.warning("chunk.backfill.failed tenant=\(tenantID) memory=\(row.memory_id): \(error)")
            }
        }

        let result = ChunkBackfillResult(
            tenantID: tenantID,
            scanned: rows.count,
            indexed: indexed,
            chunks: chunks,
            alreadyIndexed: 0,
            failed: failed
        )
        logger.info(
            "chunk.backfill tenant=\(tenantID) scanned=\(result.scanned) indexed=\(result.indexed) chunks=\(result.chunks) failed=\(result.failed)"
        )
        return result
    }

    /// True when this tenant has no un-chunked memories left.
    func isComplete(tenantID: UUID) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for chunk backfill")
        }
        let rows = try await sql.raw("""
        SELECT 1 AS remaining
        FROM memories m
        LEFT JOIN memory_chunks c
            ON c.memory_id = m.id AND c.tenant_id = m.tenant_id
        WHERE m.tenant_id = \(bind: tenantID) AND c.chunk_id IS NULL
        LIMIT 1
        """).all(decoding: BackfillRemainingRow.self)
        return rows.isEmpty
    }

    /// Read the raw vault file so chunk line numbers match the file a user
    /// would open. Returns nil for any read failure — the caller falls back to
    /// the memory's stored content rather than skipping the memory.
    private func readSource(tenantID: UUID, path: String?) -> String? {
        guard let path else { return nil }
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        // Same boundary check the vault read path uses: a `path` column value
        // is not automatically trustworthy just because we wrote it.
        guard let url = try? VaultController.resolveInside(rawRoot: rawRoot, relative: path) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private struct BackfillCandidateRow: Decodable {
    let memory_id: UUID
    let content: String
    let space_id: UUID?
    let vault_file_id: UUID?
    let source_path: String?
}

private struct BackfillRemainingRow: Decodable {
    let remaining: Int
}
