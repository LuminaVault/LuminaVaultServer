import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

// MARK: - Cost budget decision

/// Result of a pre-request **USD** budget check for a paid upstream in
/// *managed* mode. Distinct from `BudgetDecision` (token tiers) — money has
/// no "degrade" lane: either there is budget or there is not.
enum CostBudgetDecision: Equatable {
    case allow
    /// Over the daily USD cap — caller returns 429 with this retry hint.
    case deny(retryAfter: TimeInterval)
}

/// Per-provider USD pricing, in **micro-dollars per million tokens**
/// (1 USD = 1_000_000 micros). Lets `usdMicros(...)` turn a token count into
/// a money figure without floats. Defaults are placeholders — set real NIM
/// rates via env before enabling managed mode.
struct ProviderCostRate: Equatable {
    /// Micro-USD charged per 1M input tokens.
    let inputPerMtokUsdMicros: Int64
    /// Micro-USD charged per 1M output tokens.
    let outputPerMtokUsdMicros: Int64

    /// Compute the micro-USD cost of a single call.
    func usdMicros(tokensIn: Int, tokensOut: Int) -> Int64 {
        let inCost = (Int64(max(0, tokensIn)) * inputPerMtokUsdMicros) / 1_000_000
        let outCost = (Int64(max(0, tokensOut)) * outputPerMtokUsdMicros) / 1_000_000
        return inCost + outCost
    }
}

// MARK: - Service

/// Daily per-tenant **USD** metering for paid upstreams in *managed* mode
/// (the platform holds the provider key, e.g. a platform-owned NVIDIA NIM
/// `nvapi-` key). Two jobs, mirroring `UsageMeterService`:
///
/// 1. **Record** — `INSERT ... ON CONFLICT DO UPDATE` into `cost_ledger`
///    after a billable call. Fire-and-forget; never blocks the hot path.
/// 2. **Check budget** — pre-request gate comparing today's spend against a
///    configured daily cap. `cap == 0` means "unlimited / disabled".
///
/// BYOK callers (user's own key) must NOT go through this service: they pay
/// the provider directly, so the platform meters nothing.
actor CostLedgerService {
    private let fluent: Fluent
    private let logger: Logger
    /// Daily cap in micro-USD for managed-mode spend. `0` disables the gate.
    private let managedDailyCapUsdMicros: Int64

    init(
        fluent: Fluent,
        managedDailyCapUsdMicros: Int64,
        logger: Logger
    ) {
        self.fluent = fluent
        self.managedDailyCapUsdMicros = managedDailyCapUsdMicros
        self.logger = logger
    }

    // MARK: - Record

    /// Upsert today's spend for `(tenantID, provider)`. Atomic under
    /// concurrent calls from the same tenant. Failures are logged and
    /// swallowed — a metering blip must never break the request.
    func record(tenantID: UUID, provider: ProviderID, usdMicros: Int64, calls: Int = 1) async {
        guard usdMicros > 0 || calls > 0 else { return }
        guard let sql = fluent.db() as? any SQLDatabase else {
            logger.warning("cost_ledger requires SQL driver, skipping record")
            return
        }
        do {
            try await sql.raw("""
            INSERT INTO cost_ledger (tenant_id, day, provider, usd_micros, calls)
            VALUES (\(bind: tenantID), CURRENT_DATE, \(bind: provider.rawValue),
                    \(bind: usdMicros), \(bind: Int64(calls)))
            ON CONFLICT (tenant_id, day, provider) DO UPDATE
                SET usd_micros = cost_ledger.usd_micros + EXCLUDED.usd_micros,
                    calls      = cost_ledger.calls      + EXCLUDED.calls
            """).run()
        } catch {
            logger.error("cost_ledger record failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "provider": .string(provider.rawValue),
                "error": .string("\(error)"),
            ])
        }
    }

    // MARK: - Query

    /// Today's total managed spend for a tenant, in micro-USD (all providers).
    func spentTodayUsdMicros(tenantID: UUID) async -> Int64 {
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }
        do {
            let row = try await sql.raw("""
            SELECT COALESCE(SUM(usd_micros), 0) AS total
            FROM cost_ledger WHERE tenant_id = \(bind: tenantID) AND day = CURRENT_DATE
            """).first()
            return (try? row?.decode(column: "total", as: Int64.self)) ?? 0
        } catch {
            logger.error("cost_ledger sum failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "error": .string("\(error)"),
            ])
            return 0
        }
    }

    // MARK: - Budget check

    /// Pre-request USD gate for managed-mode paid calls. BYOK callers should
    /// pass `isManaged: false` and always get `.allow` (they pay the provider
    /// directly). When the cap is `0`, the gate is disabled.
    func checkBudget(tenantID: UUID, isManaged: Bool) async -> CostBudgetDecision {
        guard isManaged, managedDailyCapUsdMicros > 0 else { return .allow }
        let spent = await spentTodayUsdMicros(tenantID: tenantID)
        if spent >= managedDailyCapUsdMicros {
            return .deny(retryAfter: Self.secondsUntilUTCMidnight())
        }
        return .allow
    }

    // MARK: - Helpers

    /// Seconds until the next UTC midnight (when `CURRENT_DATE` rolls over and
    /// the daily ledger resets). Used as the 429 `Retry-After` hint.
    static func secondsUntilUTCMidnight(now: Date = Date()) -> TimeInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let next = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        return max(60, next.timeIntervalSince(now))
    }
}
