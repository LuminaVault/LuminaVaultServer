import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit

/// HER-234 — creates and drops per-tenant partial HNSW indexes on
/// `memories.embedding`. Pairs with `M39_HnswAndTsvector`, which provides
/// the baseline global HNSW index every tenant falls back to until its
/// dedicated index exists.
///
/// Per-tenant indexes use `WHERE tenant_id = '<uuid>'` so each tenant
/// gets a small, fast graph instead of fighting for cache space in the
/// global one. The trade-off is one more index per active tenant — the
/// row width on `pg_indexes` grows, which becomes a `REINDEX` chore once
/// many tenants exist (filed as a follow-up).
///
/// **Concurrency contract**: every public method here issues `CREATE` /
/// `DROP INDEX CONCURRENTLY`. Postgres refuses those inside a
/// transaction, so the caller MUST NOT wrap them in
/// `fluent.db().transaction { ... }`. Vault-init and account-deletion
/// already run outside transactions.
struct TenantVectorIndexService: Sendable {
    let fluent: Fluent
    let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    /// Idempotent — Postgres `IF NOT EXISTS` plus a deterministic index
    /// name. Safe to invoke on every vault-init call, including the
    /// "already initialised" branch.
    func ensureIndex(for tenantID: UUID) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HermesIndexError.sqlDriverRequired
        }
        let name = Self.indexName(for: tenantID)
        // Index name is sanitised (UUID hex only) so direct interpolation
        // is safe. `tenant_id` literal is also UUID-shaped — Postgres parses
        // it as a uuid in the partial-index predicate.
        try await sql.raw("""
        CREATE INDEX CONCURRENTLY IF NOT EXISTS \(unsafeRaw: "\"\(name)\"")
        ON memories
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        WHERE tenant_id = \(unsafeRaw: "'\(tenantID.uuidString)'")::uuid
        """).run()
        logger.info("hnsw.index.ensured tenant=\(tenantID) index=\(name)")
    }

    /// Idempotent — `IF EXISTS` swallows a missing index.
    func dropIndex(for tenantID: UUID) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HermesIndexError.sqlDriverRequired
        }
        let name = Self.indexName(for: tenantID)
        try await sql.raw("""
        DROP INDEX CONCURRENTLY IF EXISTS \(unsafeRaw: "\"\(name)\"")
        """).run()
        logger.info("hnsw.index.dropped tenant=\(tenantID) index=\(name)")
    }

    /// Deterministic, max-63-char Postgres identifier. Hex-only after the
    /// fixed prefix so it is always quote-safe.
    static func indexName(for tenantID: UUID) -> String {
        "idx_memories_emb_t_\(tenantID.uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    enum HermesIndexError: Error {
        case sqlDriverRequired
    }
}
