import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit

/// Per-user daily grace + per-leg platform-wide daily ceilings for the free lane.
///
/// Both ceilings exist for the same reason: OpenRouter's free-model limits are
/// **account-wide, not per user** (20 req/min, and 50 req/day until $10 of credit
/// has ever been purchased, 1000/day after). Without a per-user cap one heavy
/// user starves everybody else; without a per-leg cap we blow through the
/// provider limit and start collecting 429s.
///
/// Storage reuses `workflow_spend_buckets` (`M109_CerberusStudio`) rather than
/// adding a table. It is already a generic atomic
/// `(scope_key, period_kind, period_start)` counter with a race-free
/// conditional-increment idiom and non-negative CHECKs. Free-lane rows live in
/// their own `freelane:` scope-key namespace, and **the unit stored in
/// `spent_usd_micros` is REQUESTS, not micro-dollars** — a free request costs
/// nothing, so counting money here would only ever store zero.
/// `reserved_usd_micros` stays 0: a free request is spent the moment it is
/// dispatched, there is nothing to reconcile, and a failed request still
/// consumed the provider's quota. `WorkflowSpendService` only ever queries
/// `tenant:*` / `global` keys, so the namespaces cannot collide.
actor FreeLaneGate {
    struct Limits: Sendable, Equatable {
        let perUserDaily: Int64
        let perLegDaily: [FreeLaneCatalog.Leg: Int64]

        static let disabled = Limits(perUserDaily: 0, perLegDaily: [:])
    }

    enum Outcome: Sendable, Equatable {
        case granted(FreeLaneCatalog.Leg)
        case exhausted(retryAfter: TimeInterval)
    }

    private let fluent: Fluent
    private let limits: Limits
    private let logger: Logger

    init(fluent: Fluent, limits: Limits, logger: Logger) {
        self.fluent = fluent
        self.limits = limits
        self.logger = logger
    }

    /// Charge the tenant's daily grace, then the first `legs` entry whose
    /// platform-wide bucket still has room.
    ///
    /// Fails **open** when the SQL driver is unavailable: a metering outage must
    /// not take chat down for every non-paying user at once, and the lane it
    /// grants costs $0 by construction, so the blast radius is provider rate
    /// limits rather than money.
    func claim(tenantID: UUID, legs: [FreeLaneCatalog.Leg]) async -> Outcome {
        guard let first = legs.first else {
            return .exhausted(retryAfter: CostLedgerService.secondsUntilUTCMidnight())
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            logger.warning("free lane gate has no SQL driver; failing open on \(first.rawValue)")
            return .granted(first)
        }

        do {
            guard try await charge(sql: sql, scopeKey: Self.tenantScopeKey(tenantID), limit: limits.perUserDaily) else {
                return .exhausted(retryAfter: CostLedgerService.secondsUntilUTCMidnight())
            }
            for leg in legs {
                let limit = limits.perLegDaily[leg] ?? 0
                if try await charge(sql: sql, scopeKey: Self.legScopeKey(leg), limit: limit) {
                    return .granted(leg)
                }
                logger.warning("free lane leg \(leg.rawValue) exhausted its daily platform ceiling")
            }
            // Every leg is full. The tenant's own grace was already charged;
            // leaving it charged is deliberate — refunding would need a second
            // write on a path that is already returning an error, and the user
            // is being told to come back tomorrow anyway.
            return .exhausted(retryAfter: CostLedgerService.secondsUntilUTCMidnight())
        } catch {
            logger.error("free lane gate failed; failing open on \(first.rawValue): \(error)")
            return .granted(first)
        }
    }

    /// Remaining per-user grace today. Read-only, for preference and dashboard
    /// surfaces.
    func remainingToday(tenantID: UUID) async -> Int64 {
        guard let sql = fluent.db() as? any SQLDatabase else { return limits.perUserDaily }
        do {
            let spent = try await spent(sql: sql, scopeKey: Self.tenantScopeKey(tenantID))
            return max(0, limits.perUserDaily - spent)
        } catch {
            logger.error("free lane remaining lookup failed: \(error)")
            return limits.perUserDaily
        }
    }

    // MARK: - Storage

    static func tenantScopeKey(_ tenantID: UUID) -> String {
        "freelane:tenant:\(tenantID.uuidString)"
    }

    static func legScopeKey(_ leg: FreeLaneCatalog.Leg) -> String {
        "freelane:leg:\(leg.rawValue)"
    }

    /// Atomic conditional increment — the same idiom as
    /// `WorkflowSpendService.reserveBucket`. `UPDATE … WHERE spent + 1 <= limit
    /// RETURNING` is race-free, so N concurrent claims against a limit of M
    /// grant exactly M. A read-then-write would let two requests both pass the
    /// last unit.
    private func charge(sql: any SQLDatabase, scopeKey: String, limit: Int64) async throws -> Bool {
        guard limit > 0 else { return false }
        let periodStart = Self.utcDay()
        try await sql.raw("""
        INSERT INTO workflow_spend_buckets (scope_key, period_kind, period_start)
        VALUES (\(bind: scopeKey), \(bind: "day"), \(bind: periodStart))
        ON CONFLICT (scope_key, period_kind, period_start) DO NOTHING
        """).run()
        let row = try await sql.raw("""
        UPDATE workflow_spend_buckets
        SET spent_usd_micros = spent_usd_micros + 1, updated_at = NOW()
        WHERE scope_key = \(bind: scopeKey) AND period_kind = \(bind: "day")
          AND period_start = \(bind: periodStart)
          AND spent_usd_micros + 1 <= \(bind: limit)
        RETURNING scope_key
        """).first()
        return row != nil
    }

    private func spent(sql: any SQLDatabase, scopeKey: String) async throws -> Int64 {
        struct Row: Decodable { let spent_usd_micros: Int64 }
        let row = try await sql.raw("""
        SELECT spent_usd_micros FROM workflow_spend_buckets
        WHERE scope_key = \(bind: scopeKey) AND period_kind = \(bind: "day")
          AND period_start = \(bind: Self.utcDay())
        """).first(decoding: Row.self)
        return row?.spent_usd_micros ?? 0
    }

    /// `period_start` is a DATE, so the bucket rolls at UTC midnight — which is
    /// also what `retryAfter` promises the client.
    static func utcDay(now: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.startOfDay(for: now)
    }
}
