import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit

// MARK: - Budget decision

/// Result of a pre-request budget check. The caller maps `.deny` to
/// HTTP 429 + `Retry-After` and `.degrade` to a model override + warning
/// header. `.allow` is the happy path.
enum BudgetDecision: Equatable {
    case allow
    /// Over soft cap — route to a cheaper/smaller model. The `model` string
    /// is the fallback the caller should swap into the request payload.
    case degrade(model: String)
    /// Over hard cap — caller must return 429 with the given retry hint.
    case deny(retryAfter: TimeInterval)
}

/// Typed error for 429 responses when the daily Mtok cap is exhausted.
/// LLMController and SkillsController map this to HTTP 429 + Retry-After.
struct UsageCapExceededError: Error, Equatable {
    let retryAfter: TimeInterval
}

// MARK: - Service

/// Daily token metering actor. Two responsibilities:
///
/// 1. **Record** — `INSERT ... ON CONFLICT DO UPDATE` into `usage_meter`
///    after each successful LLM response. Fire-and-forget from the hot
///    path (never blocks the response).
///
/// 2. **Check budget** — pre-request gate that compares today's aggregate
///    against the configured daily cap for the user's tier. Returns a
///    `BudgetDecision` so the caller can degrade or deny.
///
/// Token units: raw token counts in the DB (`BIGINT`). Config caps are
/// in *million* tokens (`Double`) and converted internally:
///   1.0 Mtok = 1_000_000 raw tokens.
///
/// Pro / Ultimate tiers have no cap (returns `.allow` unconditionally).
actor UsageMeterService {
    private let fluent: Fluent
    private let logger: Logger

    /// Hard daily cap in raw tokens for free/trial tier.
    private let freeCapTokens: Int64
    /// Soft cap at 80% — triggers degrade.
    private let freeSoftCapTokens: Int64
    /// Per-skill daily cap in raw tokens.
    private let perSkillCapTokens: Int64
    /// Model to downgrade to when soft-capped.
    let degradeModel: String

    init(
        fluent: Fluent,
        freeMtokDaily: Double,
        perSkillMtokDaily: Double,
        degradeModel: String,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.logger = logger
        self.degradeModel = degradeModel
        freeCapTokens = Int64(freeMtokDaily * 1_000_000)
        freeSoftCapTokens = Int64(freeMtokDaily * 1_000_000 * 0.8)
        perSkillCapTokens = Int64(perSkillMtokDaily * 1_000_000)
    }

    // MARK: - Record

    /// Upsert today's usage for `(tenantID, model)`. Atomic — safe under
    /// concurrent requests from the same tenant.
    func record(tenantID: UUID, model: String, tokensIn: Int, tokensOut: Int) async {
        guard tokensIn > 0 || tokensOut > 0 else { return }
        guard let sql = fluent.db() as? any SQLDatabase else {
            logger.warning("usage_meter requires SQL driver, skipping record")
            return
        }
        do {
            try await sql.raw("""
            INSERT INTO usage_meter (tenant_id, day, model, mtok_in, mtok_out)
            VALUES (\(bind: tenantID), CURRENT_DATE, \(bind: model),
                    \(bind: Int64(tokensIn)), \(bind: Int64(tokensOut)))
            ON CONFLICT (tenant_id, day, model) DO UPDATE
                SET mtok_in  = usage_meter.mtok_in  + EXCLUDED.mtok_in,
                    mtok_out = usage_meter.mtok_out + EXCLUDED.mtok_out
            """).run()
        } catch {
            // Metering failures must never break the LLM hot path.
            logger.error("usage_meter record failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "error": .string("\(error)"),
            ])
        }
    }

    // MARK: - Budget check (tier-wide)

    /// Pre-request budget gate. Sums today's total `(mtok_in + mtok_out)`
    /// across all models for this tenant and compares against the tier cap.
    ///
    /// - Pro / Ultimate: always `.allow`.
    /// - Trial / free: `.allow` < 80% → `.degrade` at 80% → `.deny` at 100%.
    /// - Lapsed / archived: always `.deny` (0 cap).
    func checkBudget(tenantID: UUID, tier: UserTier) async -> BudgetDecision {
        switch tier {
        case .pro, .ultimate:
            return .allow
        case .lapsed, .archived:
            return .deny(retryAfter: Self.hoursUntilUTCMidnight())
        case .trial:
            break // continue to DB check
        }

        guard let sql = fluent.db() as? any SQLDatabase else {
            // Fail-open if DB is unavailable — better to serve than to block.
            logger.warning("usage_meter budget check: SQL driver unavailable, allowing")
            return .allow
        }

        struct UsageRow: Decodable {
            let total: Int64

            enum CodingKeys: String, CodingKey {
                case total
            }
        }

        do {
            let row = try await sql.raw("""
            SELECT COALESCE(SUM(mtok_in + mtok_out), 0) AS total
            FROM usage_meter
            WHERE tenant_id = \(bind: tenantID)
              AND day = CURRENT_DATE
            """).first(decoding: UsageRow.self)

            let used = row?.total ?? 0

            if used >= freeCapTokens {
                let retry = Self.hoursUntilUTCMidnight()
                logger.info("usage cap exceeded", metadata: [
                    "tenant_id": .string(tenantID.uuidString),
                    "used": .string("\(used)"),
                    "cap": .string("\(freeCapTokens)"),
                ])
                return .deny(retryAfter: retry)
            }

            if used >= freeSoftCapTokens {
                logger.info("usage soft cap hit, degrading", metadata: [
                    "tenant_id": .string(tenantID.uuidString),
                    "used": .string("\(used)"),
                    "soft_cap": .string("\(freeSoftCapTokens)"),
                ])
                return .degrade(model: degradeModel)
            }

            return .allow
        } catch {
            logger.error("usage_meter budget check failed", metadata: [
                "error": .string("\(error)"),
            ])
            return .allow // fail-open
        }
    }

    // MARK: - Budget check (per-skill)

    /// Per-skill daily budget gate. Sums today's usage for rows where
    /// `model` starts with `'skill:<skillName>/'` (tagged by SkillRunner
    /// when recording). Compared against `perSkillMtokDaily`.
    ///
    /// Returns `.allow` when within budget or when per-skill cap is 0
    /// (unlimited). Returns `.deny` when exceeded.
    func checkSkillBudget(tenantID: UUID, skillName: String) async -> BudgetDecision {
        guard perSkillCapTokens > 0 else { return .allow }
        guard let sql = fluent.db() as? any SQLDatabase else {
            return .allow
        }

        struct UsageRow: Decodable {
            let total: Int64
        }

        let prefix = "skill:\(skillName)/"
        do {
            let row = try await sql.raw("""
            SELECT COALESCE(SUM(mtok_in + mtok_out), 0) AS total
            FROM usage_meter
            WHERE tenant_id = \(bind: tenantID)
              AND day = CURRENT_DATE
              AND model LIKE \(bind: prefix + "%")
            """).first(decoding: UsageRow.self)

            let used = row?.total ?? 0
            if used >= perSkillCapTokens {
                logger.info("per-skill budget exceeded", metadata: [
                    "tenant_id": .string(tenantID.uuidString),
                    "skill": .string(skillName),
                    "used": .string("\(used)"),
                    "cap": .string("\(perSkillCapTokens)"),
                ])
                return .deny(retryAfter: Self.hoursUntilUTCMidnight())
            }
            return .allow
        } catch {
            logger.error("usage_meter skill budget check failed", metadata: [
                "error": .string("\(error)"),
            ])
            return .allow
        }
    }

    // MARK: - Helpers

    /// Seconds until the next UTC midnight. Minimum 1 second to satisfy
    /// `Retry-After` semantics.
    private static func hoursUntilUTCMidnight() -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let midnight = calendar.startOfDay(for: tomorrow)
        return max(1, midnight.timeIntervalSince(now))
    }
}
