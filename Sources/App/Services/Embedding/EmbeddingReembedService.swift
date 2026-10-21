import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle
import SQLKit

/// Rewrites every stored text embedding through the active provider, once.
///
/// Production ran on `EmbeddingProviderKind.deterministic` (hash-based fake
/// vectors) for its whole life, so every stored vector is noise and turning
/// a real provider on only fixes rows written afterwards. This job walks the
/// existing rows and re-embeds them, then goes idle.
///
/// ## What it touches
/// The tables in `Target.all` — every `vector(1536)` column fed by the text
/// embedder: `memories`, `memory_chunks`, `memories_archive` (an archived row
/// is revived by copying it back, vector included, so it has to be in the
/// same space). `photo_index` is embedded by the vision provider and is left
/// alone. Only rows that already have an embedding are rewritten: a NULL is
/// not a fake vector but a missing one, and the heal pass below fills it in.
///
/// Each write sets the embedding column and nothing else (no `updated_at`,
/// no review state), and only while the row's text is still the text that was
/// embedded — a row edited or re-chunked mid-batch already got a real vector
/// from its writer and is left as it is.
///
/// ## Order, pacing, resume
/// Rows go in primary-key order, `batchSize` at a time, one embed call per
/// row through the tenant-aware service (a BYO-key tenant is billed to its own
/// key), with `pause` between batches. The cursor in
/// `embedding_reembed_progress` (M149) is written after every batch, so a
/// restart resumes after the last finished batch; a finished target gets
/// `completed_at` and is never walked again (delete its row to re-run it).
///
/// ## Failures
/// A row whose embed fails keeps its old vector, is logged and counted in
/// `rows_failed`, and does not hold up the batch. A batch where *every* row
/// failed is a provider problem rather than a bad row (no credit, auth, an
/// outage): the cursor stays put so nothing is skipped, and after
/// `failedBatchesBeforeBackoff` such batches in a row the wait between
/// attempts doubles from `backoffBase` up to `maxBackoff`.
///
/// ## Refusal
/// With the deterministic stub active the job does nothing: re-embedding
/// would overwrite noise with the same noise and then mark itself complete,
/// so the real switch later would find nothing left to do.
///
/// ## Derived state
/// The 3D graph layout (`memories.graph_x/y/z`, `GraphLayoutService`) is a
/// projection of the memory vectors. When `memories` finishes, its
/// coordinates are cleared so `GraphLayoutWorker` lays the tenant out again
/// from the real vectors on its next tick; the client force-directs nodes
/// without coordinates in the meantime.
///
/// ## Heal pass (missing embeddings)
/// Write paths save a row with `embedding = NULL` when the provider fails
/// (`EmbeddingService.embedForWrite`), so a capture is never lost to an
/// outage or an empty balance. Once the re-embed is complete (or straight
/// away when it is not enabled) the service keeps running a heal pass over
/// `healTargets` (`memories`, `memory_chunks`): rows with a NULL embedding
/// and non-blank text, in primary-key order, `batchSize` at a time with
/// `pause` between full batches, until it reaches the end; then it waits
/// `healInterval` and starts again from the top. It writes only while the
/// row is still NULL and its text unchanged, so it never overwrites a vector
/// a writer set in the meantime.
///
/// A row that fails on its own (a rejected input) is skipped and retried on
/// the next pass. A failure that means the provider cannot serve anyone
/// (`EmbeddingProviderError.isProviderUnavailable`: outage, 402, bad key)
/// ends the pass after that one call, and the next attempt waits
/// `healInterval` doubling up to `healMaxBackoff` — one probe per window,
/// not one per row. The cursor stays past the failed row, so a single
/// BYO-key tenant with a revoked key cannot stall everyone behind it.
///
/// Single replica, like `GraphLayoutWorker`: a second replica would redo
/// batches (an idempotent overwrite, but paid twice).
actor EmbeddingReembedService: Service {
    struct Target: Sendable, Equatable {
        /// Key in `embedding_reembed_progress`.
        let name: String
        let table: String
        let idColumn: String
        /// SQL type of `idColumn`; the cursor is stored as text and cast back.
        let idType: String
        let textColumn: String
        /// Clear the persisted graph layout once this target finishes.
        let clearsGraphLayout: Bool

        static let memories = Target(
            name: "memories", table: "memories", idColumn: "id", idType: "uuid",
            textColumn: "content", clearsGraphLayout: true
        )
        static let memoryChunks = Target(
            name: "memory_chunks", table: "memory_chunks", idColumn: "chunk_id", idType: "text",
            textColumn: "text", clearsGraphLayout: false
        )
        static let memoriesArchive = Target(
            name: "memories_archive", table: "memories_archive", idColumn: "id", idType: "uuid",
            textColumn: "content", clearsGraphLayout: false
        )
        /// Live recall first: whole-memory vectors, then chunks, then cold storage.
        static let all: [Target] = [.memories, .memoryChunks, .memoriesArchive]
        /// What the heal pass fills in. The archive is cold storage nobody
        /// writes to with a NULL on purpose; it is left to the re-embed.
        static let healable: [Target] = [.memories, .memoryChunks]
    }

    struct Configuration: Sendable {
        var batchSize = 50
        var pause: Duration = .seconds(2)
        var failedBatchesBeforeBackoff = 3
        var backoffBase: Duration = .seconds(30)
        var maxBackoff: Duration = .seconds(900)
        /// Wait between heal passes once caught up, and the first backoff
        /// after a pass the provider refused.
        var healInterval: Duration = .seconds(600)
        /// Ceiling for the doubling heal backoff.
        var healMaxBackoff: Duration = .seconds(3600)
    }

    /// What one heal pass did.
    enum HealResult: Equatable {
        /// Reached the end of every heal target.
        case caughtUp(healed: Int, failed: Int)
        /// Stopped at a failure that means the provider is unavailable.
        case providerUnavailable(healed: Int)
        /// The deterministic stub is active.
        case refused
    }

    /// What one batch did.
    enum BatchResult: Equatable {
        /// Rows were looked at and the cursor moved past them.
        case progressed(reembedded: Int, failed: Int, skipped: Int)
        /// Every row failed; the cursor did not move.
        case providerFailed(failed: Int)
        /// No rows left; the target is now marked complete.
        case completed
        /// The target was already complete.
        case alreadyComplete
    }

    struct Progress: Equatable {
        let lastID: String?
        let rowsDone: Int64
        let rowsFailed: Int64
        let completedAt: Date?
    }

    private let fluent: Fluent
    private let embeddings: any EmbeddingService
    private let activeKind: EmbeddingProviderKind
    private let targets: [Target]
    private let healTargets: [Target]
    private let reembedEnabled: Bool
    private let healEnabled: Bool
    private let configuration: Configuration
    private let logger: Logger
    private let sleep: @Sendable (Duration) async throws -> Void

    private var consecutiveFailedBatches = 0
    private var consecutiveFailedHeals = 0
    /// Heal position per target (last id looked at), in memory only: after a
    /// restart the first pass simply starts from the top.
    private var healCursors: [String: String] = [:]

    /// - Parameters:
    ///   - reembedEnabled: run the one-shot re-embed first
    ///     (`EMBEDDING_REEMBED_ENABLED`). When false the heal pass starts
    ///     straight away.
    ///   - healEnabled: keep running the heal pass afterwards
    ///     (`EMBEDDING_HEAL_ENABLED`).
    init(
        fluent: Fluent,
        embeddings: any EmbeddingService,
        activeKind: EmbeddingProviderKind,
        targets: [Target] = Target.all,
        healTargets: [Target] = Target.healable,
        reembedEnabled: Bool = true,
        healEnabled: Bool = true,
        configuration: Configuration = Configuration(),
        logger: Logger = Logger(label: "lv.embedding.reembed"),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.fluent = fluent
        self.embeddings = embeddings
        self.activeKind = activeKind
        self.targets = targets
        self.healTargets = healTargets
        self.reembedEnabled = reembedEnabled
        self.healEnabled = healEnabled
        var configuration = configuration
        configuration.batchSize = max(1, configuration.batchSize)
        configuration.failedBatchesBeforeBackoff = max(1, configuration.failedBatchesBeforeBackoff)
        configuration.healMaxBackoff = max(configuration.healInterval, configuration.healMaxBackoff)
        self.configuration = configuration
        self.logger = logger
        self.sleep = sleep
    }

    func run() async throws {
        do {
            try await cancelWhenGracefulShutdown { [self] in
                if reembedEnabled {
                    guard try await runToCompletion() else { return }
                }
                if healEnabled {
                    try await runHealLoop()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("embedding.reembed stopped: \(error)")
        }
        // Returning would end the ServiceGroup (and the app) — idle until the
        // app shuts down instead.
        try? await gracefulShutdown()
    }

    /// Walks every target to completion. Returns false when refused (the
    /// deterministic stub is active). Exposed so tests drive it without a
    /// `ServiceGroup`.
    @discardableResult
    func runToCompletion() async throws -> Bool {
        guard activeKind != .deterministic else {
            logger.warning(
                "embedding.reembed refused: active embedding provider is deterministic, so re-embedding would only rewrite hash noise. Set EMBEDDING_PROVIDER to a real provider (e.g. openrouter) first."
            )
            return false
        }
        logger.info("embedding.reembed started provider=\(activeKind.rawValue) targets=\(targets.map(\.name).joined(separator: ",")) batch=\(configuration.batchSize)")
        for target in targets {
            try await runTarget(target)
        }
        logger.info("embedding.reembed all targets complete")
        return true
    }

    private func runTarget(_ target: Target) async throws {
        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            switch try await runBatch(target) {
            case .alreadyComplete:
                logger.debug("embedding.reembed target=\(target.name) already complete")
                return
            case .completed:
                let progress = try await progress(for: target)
                logger.info(
                    "embedding.reembed complete target=\(target.name) rows_done=\(progress?.rowsDone ?? 0) rows_failed=\(progress?.rowsFailed ?? 0) elapsed=\(ContinuousClock.now - started)"
                )
                return
            case .progressed:
                try await sleep(configuration.pause)
            case .providerFailed:
                try await sleep(delayAfterFailedBatch())
            }
        }
    }

    /// One batch of `target`. Exposed so tests can step through a target.
    func runBatch(_ target: Target) async throws -> BatchResult {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw ReembedError.sqlRequired
        }
        guard activeKind != .deterministic else { return .alreadyComplete }
        let current = try await progress(for: target)
        if current?.completedAt != nil {
            return .alreadyComplete
        }

        let rows = try await fetchBatch(sql, target: target, after: current?.lastID)
        guard let last = rows.last else {
            try await markComplete(sql, target: target)
            return .completed
        }

        var reembedded = 0
        var failed = 0
        var skipped = 0
        for row in rows {
            guard !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped += 1
                continue
            }
            do {
                let vector = try await embeddings.embed(row.text, tenantID: row.tenant_id)
                guard vector.count == OpenAIEmbeddingService.targetDim else {
                    throw EmbeddingProviderError.dimMismatch(expected: OpenAIEmbeddingService.targetDim, got: vector.count)
                }
                if try await write(sql, target: target, row: row, vector: vector) {
                    reembedded += 1
                } else {
                    skipped += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Shutdown surfaces from URLSession as a network error, not a
                // CancellationError. Counting it would advance the cursor past
                // rows that never got a real vector, so stop without saving.
                try Task.checkCancellation()
                failed += 1
                logger.warning("embedding.reembed row failed target=\(target.name) id=\(row.id) tenant=\(row.tenant_id): \(error)")
            }
        }

        if reembedded == 0, skipped == 0, failed > 0 {
            consecutiveFailedBatches += 1
            logger.warning(
                "embedding.reembed batch failed target=\(target.name) after=\(current?.lastID ?? "start") failed=\(failed) consecutive=\(consecutiveFailedBatches); cursor not advanced"
            )
            return .providerFailed(failed: failed)
        }
        consecutiveFailedBatches = 0
        try await advance(sql, target: target, lastID: last.id, done: reembedded, failed: failed)
        logger.debug(
            "embedding.reembed batch target=\(target.name) rows=\(rows.count) reembedded=\(reembedded) failed=\(failed) skipped=\(skipped) last=\(last.id)"
        )
        return .progressed(reembedded: reembedded, failed: failed, skipped: skipped)
    }

    func progress(for target: Target) async throws -> Progress? {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw ReembedError.sqlRequired
        }
        struct Row: Decodable {
            let last_id: String?
            let rows_done: Int64
            let rows_failed: Int64
            let completed_at: Date?
        }
        let row = try await sql.raw("""
        SELECT last_id, rows_done, rows_failed, completed_at
        FROM embedding_reembed_progress
        WHERE target = \(bind: target.name)
        """).first(decoding: Row.self)
        return row.map { Progress(lastID: $0.last_id, rowsDone: $0.rows_done, rowsFailed: $0.rows_failed, completedAt: $0.completed_at) }
    }

    /// `pause` until the provider has failed `failedBatchesBeforeBackoff`
    /// batches in a row, then `backoffBase` doubling up to `maxBackoff`.
    func delayAfterFailedBatch() -> Duration {
        let threshold = configuration.failedBatchesBeforeBackoff
        guard consecutiveFailedBatches >= threshold else { return configuration.pause }
        let exponent = min(consecutiveFailedBatches - threshold, 16)
        let delay = configuration.backoffBase * (1 << exponent)
        let capped = min(delay, configuration.maxBackoff)
        logger.warning("embedding.reembed backing off \(capped) after \(consecutiveFailedBatches) failed batches")
        return capped
    }

    // MARK: - Heal pass

    /// Heal passes until shutdown, `delayAfterHeal` apart. A pass that throws
    /// (the database, not the provider) counts as failed and backs off too,
    /// so one bad query does not end healing for the life of the process.
    private func runHealLoop() async throws {
        logger.info(
            "embedding.heal started provider=\(activeKind.rawValue) targets=\(healTargets.map(\.name).joined(separator: ",")) interval=\(configuration.healInterval)"
        )
        while true {
            try Task.checkCancellation()
            let result: HealResult
            do {
                result = try await healMissing()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                logger.error("embedding.heal pass failed: \(error)")
                result = .providerUnavailable(healed: 0)
            }
            if result == .refused {
                return
            }
            try await sleep(delayAfterHeal(result))
        }
    }

    /// One heal pass over every heal target, resuming each where the last
    /// pass stopped. Exposed so tests drive it without a `ServiceGroup`.
    @discardableResult
    func healMissing() async throws -> HealResult {
        guard activeKind != .deterministic else {
            logger.warning("embedding.heal refused: active embedding provider is deterministic")
            return .refused
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw ReembedError.sqlRequired
        }
        var healed = 0
        var failed = 0
        for target in healTargets {
            while true {
                try Task.checkCancellation()
                let rows = try await fetchBatch(sql, target: target, after: healCursors[target.name], missing: true)
                for row in rows {
                    do {
                        let vector = try await embeddings.embed(row.text, tenantID: row.tenant_id)
                        guard vector.count == OpenAIEmbeddingService.targetDim else {
                            throw EmbeddingProviderError.dimMismatch(expected: OpenAIEmbeddingService.targetDim, got: vector.count)
                        }
                        if try await write(sql, target: target, row: row, vector: vector, onlyIfMissing: true) {
                            healed += 1
                        }
                        healCursors[target.name] = row.id
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Shutdown surfaces from URLSession as a network error.
                        try Task.checkCancellation()
                        healCursors[target.name] = row.id
                        if let providerError = error as? EmbeddingProviderError, !providerError.isProviderUnavailable {
                            failed += 1
                            logger.warning("embedding.heal row failed target=\(target.name) id=\(row.id) tenant=\(row.tenant_id): \(error)")
                            continue
                        }
                        logger.warning(
                            "embedding.heal provider unavailable target=\(target.name) tenant=\(row.tenant_id) healed=\(healed): \(error)"
                        )
                        return .providerUnavailable(healed: healed)
                    }
                }
                if rows.count < configuration.batchSize {
                    // End of the table: the next pass starts from the top, so
                    // rows skipped this time are tried again.
                    healCursors[target.name] = nil
                    break
                }
                try await sleep(configuration.pause)
            }
        }
        if healed > 0 || failed > 0 {
            logger.info("embedding.heal pass complete healed=\(healed) failed=\(failed)")
        }
        return .caughtUp(healed: healed, failed: failed)
    }

    /// `healInterval` after a pass that caught up; after a refused one,
    /// `healInterval` doubling per consecutive refusal up to `healMaxBackoff`.
    func delayAfterHeal(_ result: HealResult) -> Duration {
        switch result {
        case .caughtUp, .refused:
            consecutiveFailedHeals = 0
            return configuration.healInterval
        case .providerUnavailable:
            consecutiveFailedHeals += 1
            let exponent = min(consecutiveFailedHeals - 1, 16)
            let delay = min(configuration.healInterval * (1 << exponent), configuration.healMaxBackoff)
            logger.warning("embedding.heal next probe in \(delay) after \(consecutiveFailedHeals) refused passes")
            return delay
        }
    }

    // MARK: - SQL

    private struct CandidateRow: Decodable {
        let id: String
        let tenant_id: UUID
        let text: String
    }

    /// Table and column names come from the static `Target` constants, never
    /// from input, so `unsafeRaw` is safe here.
    ///
    /// The re-embed reads rows that have a vector; the heal pass (`missing`)
    /// reads rows without one whose text is not blank — a blank row has
    /// nothing to embed and would otherwise be read on every pass.
    private func fetchBatch(
        _ sql: any SQLDatabase,
        target: Target,
        after cursor: String?,
        missing: Bool = false
    ) async throws -> [CandidateRow] {
        let id = target.idColumn
        let filter = missing
            ? "embedding IS NULL AND btrim(\(target.textColumn)) <> ''"
            : "embedding IS NOT NULL"
        if let cursor {
            return try await sql.raw("""
            SELECT \(unsafeRaw: id)::text AS id, tenant_id, \(unsafeRaw: target.textColumn) AS text
            FROM \(unsafeRaw: target.table)
            WHERE \(unsafeRaw: filter)
              AND \(unsafeRaw: id) > \(bind: cursor)::\(unsafeRaw: target.idType)
            ORDER BY \(unsafeRaw: id)
            LIMIT \(bind: configuration.batchSize)
            """).all(decoding: CandidateRow.self)
        }
        return try await sql.raw("""
        SELECT \(unsafeRaw: id)::text AS id, tenant_id, \(unsafeRaw: target.textColumn) AS text
        FROM \(unsafeRaw: target.table)
        WHERE \(unsafeRaw: filter)
        ORDER BY \(unsafeRaw: id)
        LIMIT \(bind: configuration.batchSize)
        """).all(decoding: CandidateRow.self)
    }

    /// Writes the embedding column only, and only if the text is unchanged.
    /// Returns false when the row was edited or deleted since it was read.
    /// `onlyIfMissing` (the heal pass) also leaves alone a row a writer gave
    /// a vector in the meantime.
    private func write(
        _ sql: any SQLDatabase,
        target: Target,
        row: CandidateRow,
        vector: [Float],
        onlyIfMissing: Bool = false
    ) async throws -> Bool {
        struct Written: Decodable { let id: String }
        let literal = "'\(MemoryRepository.formatVector(vector))'::vector"
        let missingGuard = onlyIfMissing ? "AND embedding IS NULL" : ""
        let written = try await sql.raw("""
        UPDATE \(unsafeRaw: target.table)
        SET embedding = \(unsafeRaw: literal)
        WHERE \(unsafeRaw: target.idColumn) = \(bind: row.id)::\(unsafeRaw: target.idType)
          AND tenant_id = \(bind: row.tenant_id)
          AND \(unsafeRaw: target.textColumn) = \(bind: row.text)
          \(unsafeRaw: missingGuard)
        RETURNING \(unsafeRaw: target.idColumn)::text AS id
        """).first(decoding: Written.self)
        return written != nil
    }

    private func advance(_ sql: any SQLDatabase, target: Target, lastID: String, done: Int, failed: Int) async throws {
        try await sql.raw("""
        INSERT INTO embedding_reembed_progress (target, last_id, rows_done, rows_failed, updated_at)
        VALUES (\(bind: target.name), \(bind: lastID), \(bind: Int64(done)), \(bind: Int64(failed)), now())
        ON CONFLICT (target) DO UPDATE
        SET last_id = EXCLUDED.last_id,
            rows_done = embedding_reembed_progress.rows_done + EXCLUDED.rows_done,
            rows_failed = embedding_reembed_progress.rows_failed + EXCLUDED.rows_failed,
            updated_at = now()
        """).run()
    }

    private func markComplete(_ sql: any SQLDatabase, target: Target) async throws {
        try await sql.raw("""
        INSERT INTO embedding_reembed_progress (target, completed_at, updated_at)
        VALUES (\(bind: target.name), now(), now())
        ON CONFLICT (target) DO UPDATE
        SET completed_at = now(), updated_at = now()
        """).run()
        if target.clearsGraphLayout {
            try await sql.raw("""
            UPDATE memories
            SET graph_x = NULL, graph_y = NULL, graph_z = NULL, graph_layout_at = NULL
            WHERE graph_x IS NOT NULL
            """).run()
        }
    }

    enum ReembedError: Error { case sqlRequired }
}
