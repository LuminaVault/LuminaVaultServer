import FluentKit
import Foundation
import HummingbirdFluent

/// HER-134 — repository for the `embedding_usage` row that backs the
/// per-tenant monthly token cap. `tokensThisMonth` is read on every
/// embed call (cap check); `increment` adds to the running monthly total.
/// The Postgres unique index on `(tenant_id, year_month)` enforces single-
/// row-per-month at the DB layer; on the rare insert/insert race we retry
/// once and let the update path win.
struct EmbeddingUsageRepository {
    let fluent: Fluent

    func tokensThisMonth(tenantID: UUID, now: Date = .init()) async throws -> Int64 {
        let ym = EmbeddingUsage.yearMonth(for: now)
        let row = try await EmbeddingUsage.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$yearMonth == ym)
            .first()
        return row?.tokensUsed ?? 0
    }

    /// Adds `tokens` to the existing month row, inserting one if absent.
    /// Two-step (not a true UPSERT) — a concurrent insert race may surface
    /// a duplicate-unique-key error on the second call, in which case we
    /// retry once via the update path.
    func increment(tenantID: UUID, tokens: Int64, now: Date = .init()) async throws {
        guard tokens > 0 else { return }
        let ym = EmbeddingUsage.yearMonth(for: now)
        let db = fluent.db()
        for attempt in 0 ..< 2 {
            if let existing = try await EmbeddingUsage.query(on: db)
                .filter(\.$tenantID == tenantID)
                .filter(\.$yearMonth == ym)
                .first()
            {
                existing.tokensUsed += tokens
                try await existing.save(on: db)
                return
            }
            do {
                try await EmbeddingUsage(tenantID: tenantID, yearMonth: ym, tokensUsed: tokens).save(on: db)
                return
            } catch {
                // Likely unique-constraint race — loop once and take the
                // update path. On the second attempt give up and surface.
                if attempt == 1 {
                    throw error
                }
            }
        }
    }
}
