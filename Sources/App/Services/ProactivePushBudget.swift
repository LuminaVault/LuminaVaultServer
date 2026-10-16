import Foundation
import HummingbirdFluent
import SQLKit

/// At most one proactive push per tenant per local day.
///
/// "Proactive" means a push the user did not ask for at that moment: the
/// learned-memory digest (Wave 3) and the daily brief (Wave 4) call `claim`
/// before sending and send only when it returns `true`. Nothing calls it yet.
///
/// Exempt — never claim, never blocked: meeting briefs (time-bound to an event
/// the user scheduled), reminders, cron jobs, approvals, run completions and
/// anything else answering something the user set up or asked for.
///
/// The cap is the `(tenant_id, day)` primary key of `proactive_push_log`
/// (M141): the insert is `ON CONFLICT DO NOTHING`, so two senders racing for
/// the same day cannot both win. `day` is the tenant's local calendar day, so
/// the budget resets at the user's midnight, not UTC's.
struct ProactivePushBudget: Sendable {
    let fluent: Fluent

    /// Claims today's proactive slot for `tenantID`. `true` means the caller
    /// won and should send; `false` means today's push was already spent.
    /// `timezone` is `users.timezone`; an unknown identifier counts as UTC.
    func claim(tenantID: UUID, kind: String, timezone: String, now: Date = Date()) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw BudgetError.requiresSQL
        }
        let day = Self.localDay(now, timezone: timezone)
        let won = try await sql.raw("""
        INSERT INTO proactive_push_log (tenant_id, day, kind, sent_at)
        VALUES (\(bind: tenantID), \(bind: day)::date, \(bind: kind), \(bind: now))
        ON CONFLICT (tenant_id, day) DO NOTHING
        RETURNING kind
        """).first()
        return won != nil
    }

    /// `yyyy-MM-dd` of `now` in `timezone` (UTC when unknown).
    static func localDay(_ now: Date, timezone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    enum BudgetError: Error { case requiresSQL }
}
