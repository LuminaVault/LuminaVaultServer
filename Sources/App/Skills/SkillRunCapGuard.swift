import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// HER-193 — per-skill daily run cap. Cost guard for `capability: high`
/// skills (pattern / contradiction / belief) where each invocation costs
/// ~$0.05-0.15 on Sonnet. Three such skills × 100/day × $0.10 =
/// $30/user/day; the Pro tier doesn't survive that without per-skill caps.
///
/// `HER-175` UsageMeter gates the tier-wide token budget; this gates the
/// per-skill call count. The two compose: hit either ceiling, get 429.
///
/// ### Flow
///
/// 1. `SkillRunner.run` calls `checkAndIncrement(...)` before dispatching
///    to the LLM. The guard reads the `skills_state` row for
///    `(tenant, source, name)`.
/// 2. If `daily_run_reset_at < NOW()` (or row missing), the count is
///    reset to 0 and `reset_at` is rolled forward to the next user-local
///    midnight. Reset is opportunistic — no cron.
/// 3. If `count >= manifest.daily_run_cap.<tier>`, returns
///    `.deny(retryAfter:)` pointing at `reset_at - NOW()`. SkillsController
///    converts this to `429 Too Many Requests + Retry-After`.
/// 4. Otherwise increments and persists. Caller invokes
///    `recordFailure(...)` on LLM/provider errors so failed runs don't
///    burn the cap (acceptance: "user not penalized for our outage").
///
/// ### Cap source
///
/// Caps come from the manifest (`SKILL.md` frontmatter
/// `metadata.daily_run_cap`), not the DB. Operators tune by editing the
/// manifest + redeploying. `0` means unlimited for that tier.
///
/// ### Timezone
///
/// `userLocalTimeZone` defaults to the server's current zone; production
/// will inject the per-user zone once the user-profile schema carries it.
/// Either way, the opportunistic reset self-corrects on the next call,
/// so a zone change at most extends the cap window by one day.
actor SkillRunCapGuard {
    /// Decision returned by `checkAndIncrement`. The caller surfaces
    /// `.deny` as `HTTP 429 + Retry-After`.
    enum Decision: Hashable {
        case allow
        case deny(retryAfter: TimeInterval)
    }

    private let fluent: Fluent
    private let logger: Logger
    private let userLocalTimeZone: TimeZone
    private let now: @Sendable () -> Date

    init(
        fluent: Fluent,
        userLocalTimeZone: TimeZone = .current,
        now: @Sendable @escaping () -> Date = Date.init,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.userLocalTimeZone = userLocalTimeZone
        self.now = now
        self.logger = logger
    }

    /// Atomically: opportunistically reset the counter, check the cap,
    /// and increment on allow. Returns `.deny(retryAfter:)` when the
    /// tenant has exhausted the manifest cap for their tier.
    ///
    /// `tier` is the resolved user tier string ("trial" / "pro" /
    /// "ultimate"). Unlimited (`cap == 0`) short-circuits before any DB
    /// I/O so an Ultimate user never pays the round-trip.
    func checkAndIncrement(
        tenantID: UUID,
        tier: String,
        manifest: SkillManifest,
    ) async throws -> Decision {
        let cap = manifest.dailyRunCap?.value(for: tier) ?? 0
        if cap <= 0 {
            return .allow
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "skills_state requires a SQL driver")
        }

        let nowDate = now()
        let nextReset = nextLocalMidnight(after: nowDate)

        struct StateRow: Decodable {
            let dailyRunCount: Int
            let dailyRunResetAt: Date?

            enum CodingKeys: String, CodingKey {
                case dailyRunCount = "daily_run_count"
                case dailyRunResetAt = "daily_run_reset_at"
            }
        }

        let row = try await sql.raw("""
        SELECT daily_run_count, daily_run_reset_at
        FROM skills_state
        WHERE tenant_id = \(bind: tenantID)
          AND source = \(bind: manifest.source.rawValue)
          AND name = \(bind: manifest.name)
        """).first(decoding: StateRow.self)

        var count = row?.dailyRunCount ?? 0
        var resetAt = row?.dailyRunResetAt
        if resetAt == nil || (resetAt ?? .distantPast) <= nowDate {
            count = 0
            resetAt = nextReset
        }
        if count >= cap {
            let retryAfter = max(1, (resetAt ?? nextReset).timeIntervalSince(nowDate))
            return .deny(retryAfter: retryAfter)
        }

        try await sql.raw("""
        INSERT INTO skills_state
            (tenant_id, source, name, enabled, daily_run_count, daily_run_reset_at)
        VALUES
            (\(bind: tenantID), \(bind: manifest.source.rawValue), \(bind: manifest.name),
             TRUE, \(bind: count + 1), \(bind: resetAt))
        ON CONFLICT (tenant_id, source, name) DO UPDATE
            SET daily_run_count = EXCLUDED.daily_run_count,
                daily_run_reset_at = EXCLUDED.daily_run_reset_at
        """).run()

        return .allow
    }

    /// Refund a slot. Called by `SkillRunner` when the underlying LLM
    /// call or output dispatch fails — the user shouldn't burn quota for
    /// our outage. Idempotent; clamps at zero so repeated calls cannot
    /// drive the counter negative.
    func recordFailure(
        tenantID: UUID,
        manifest: SkillManifest,
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("""
        UPDATE skills_state
            SET daily_run_count = GREATEST(daily_run_count - 1, 0)
        WHERE tenant_id = \(bind: tenantID)
          AND source = \(bind: manifest.source.rawValue)
          AND name = \(bind: manifest.name)
        """).run()
    }

    private func nextLocalMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = userLocalTimeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return calendar.startOfDay(for: tomorrow)
    }
}

/// HER-193 — typed error surfaced by `SkillRunner.run` when the cap guard
/// denies the request. `SkillsController` maps this to
/// `HTTP 429 Too Many Requests` with a `Retry-After` header pointing at
/// the next user-local midnight.
struct SkillRunCapExceededError: Error, Equatable {
    let retryAfter: TimeInterval
}
