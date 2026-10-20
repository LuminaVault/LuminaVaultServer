import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle
import SQLKit

/// "What I learned this week" — once a week, Sunday between 18:00 and 18:59
/// on the user's own clock (`users.timezone`), a quiet push saying how many
/// things Lumina learned and is waiting for them to keep, edit or forget.
///
/// ## Once a week
/// `learned_digest_log (tenant_id, week_start)` is the weekly cap. `week_start`
/// is the local Monday of the week the Sunday closes. A user is a candidate
/// only while they have no row for this week, and the row is claimed with
/// `INSERT … ON CONFLICT DO NOTHING RETURNING`, so two replicas ticking the
/// same minute cannot both send.
///
/// ## Empty weeks
/// The digest is built *before* claiming. An empty digest still writes the
/// week's row (`outcome = 'empty'`) so the user stops being a candidate: it
/// is not rebuilt every minute for the rest of the hour, and something learned
/// at 18:30 waits for the app rather than turning into a late push.
///
/// ## Order of the gates, after a non-empty digest
/// 1. Claim the week. Lost → another replica has it.
/// 2. Digest opt-out (`apns_category_prefs.digest_enabled = false`) or no
///    device → recorded, nothing sent, and the day's budget is left alone
///    for a push that could actually arrive.
/// 3. `ProactivePushBudget.claim(kind: "learned")` for the local day. Lost →
///    recorded as `budget_spent`; there is no retry later that week.
/// 4. Send (category `.digest`, so the opt-out gates it there too).
actor LearnedDigestScheduler: Service {
    static let budgetKind = "learned"
    static let actionCategory = "learned"
    static let threadID = "learned"
    static let deepLink = "luminavault://learned"
    static let title = "What I learned this week"
    /// Sunday in `Calendar.component(.weekday)`.
    static let sendWeekday = 1
    static let sendHour = 18

    enum Outcome: String {
        case sent
        case empty
        case optedOut = "opted_out"
        case noDevice = "no_device"
        case budgetSpent = "budget_spent"
        case failed
    }

    private let fluent: Fluent
    private let push: APNSNotificationService?
    private let logger: Logger
    private let tickInterval: Duration
    private let digest: MeLearnedService
    private let budget: ProactivePushBudget

    init(
        fluent: Fluent,
        push: APNSNotificationService?,
        logger: Logger,
        tickInterval: Duration = .seconds(60)
    ) {
        self.fluent = fluent
        self.push = push
        self.logger = logger
        self.tickInterval = tickInterval
        digest = MeLearnedService(fluent: fluent)
        budget = ProactivePushBudget(fluent: fluent)
    }

    func run() async throws {
        logger.info("learned.digest scheduler started (tick=\(tickInterval))")
        while !Task.isCancelled {
            do {
                let sent = try await tick(at: Date())
                if sent > 0 {
                    logger.info("learned.digest tick sent=\(sent)")
                }
            } catch {
                logger.warning("learned.digest tick error \(error)")
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// One pass at `now`. Returns how many digests were sent. Exposed so tests
    /// drive the clock.
    @discardableResult
    func tick(at now: Date) async throws -> Int {
        guard !fluent.databases.ids().isEmpty else { return 0 }
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }

        // Only a handful of distinct zones exist; work out in Swift which are
        // in their Sunday-18 hour rather than asking Postgres to parse every
        // stored identifier (an unknown one would fail the whole query).
        struct ZoneRow: Decodable { let timezone: String }
        let zones = try await sql.raw("SELECT DISTINCT timezone FROM users").all(decoding: ZoneRow.self)

        var sent = 0
        for zone in zones.map(\.timezone) {
            guard let weekStart = Self.weekStartIfSendHour(now: now, timezone: zone) else { continue }
            struct Candidate: Decodable { let id: UUID }
            let candidates = try await sql.raw("""
            SELECT u.id
            FROM users u
            WHERE u.timezone = \(bind: zone)
              -- the log row hangs off the personal vault
              AND EXISTS (SELECT 1 FROM vaults v WHERE v.id = u.id)
              AND NOT EXISTS (
                  SELECT 1 FROM learned_digest_log l
                  WHERE l.tenant_id = u.id AND l.week_start = \(bind: weekStart)::date
              )
            """).all(decoding: Candidate.self)
            for candidate in candidates {
                do {
                    if try await deliver(sql, tenantID: candidate.id, timezone: zone, weekStart: weekStart, now: now) == .sent {
                        sent += 1
                    }
                } catch {
                    logger.warning("learned.digest failed tenant=\(candidate.id): \(error)")
                }
            }
        }
        return sent
    }

    private func deliver(_ sql: any SQLDatabase, tenantID: UUID, timezone: String, weekStart: String, now: Date) async throws -> Outcome? {
        let learned = try await digest.build(
            tenantID: tenantID,
            since: now.addingTimeInterval(-MeLearnedService.defaultWindow),
            now: now
        )
        guard let body = MeLearnedService.pushBody(for: learned) else {
            _ = try await claimWeek(sql, tenantID: tenantID, weekStart: weekStart, outcome: .empty, now: now)
            return .empty
        }
        guard try await claimWeek(sql, tenantID: tenantID, weekStart: weekStart, outcome: .sent, now: now) else {
            return nil
        }

        let db = fluent.db()
        if try await APNSNotificationService.isCategorySuppressed(.digest, tenantID: tenantID, on: db) {
            try await record(sql, tenantID: tenantID, weekStart: weekStart, outcome: .optedOut)
            return .optedOut
        }
        if try await DeviceToken.query(on: db, tenantID: tenantID).count() == 0 {
            try await record(sql, tenantID: tenantID, weekStart: weekStart, outcome: .noDevice)
            return .noDevice
        }
        guard try await budget.claim(tenantID: tenantID, kind: Self.budgetKind, timezone: timezone, now: now) else {
            try await record(sql, tenantID: tenantID, weekStart: weekStart, outcome: .budgetSpent)
            return .budgetSpent
        }
        guard let push else { return .sent }
        do {
            try await push.notify(
                userID: tenantID,
                title: Self.title,
                subtitle: nil,
                body: body,
                category: .digest,
                payload: ["deepLink": Self.deepLink],
                interruptionLevel: .passive,
                threadID: Self.threadID,
                actionCategory: Self.actionCategory
            )
            return .sent
        } catch {
            try? await record(sql, tenantID: tenantID, weekStart: weekStart, outcome: .failed)
            throw error
        }
    }

    /// `true` when this caller inserted the week's row.
    private func claimWeek(
        _ sql: any SQLDatabase,
        tenantID: UUID,
        weekStart: String,
        outcome: Outcome,
        now: Date
    ) async throws -> Bool {
        let won = try await sql.raw("""
        INSERT INTO learned_digest_log (tenant_id, week_start, sent_at, outcome)
        VALUES (\(bind: tenantID), \(bind: weekStart)::date, \(bind: now), \(bind: outcome.rawValue))
        ON CONFLICT (tenant_id, week_start) DO NOTHING
        RETURNING outcome
        """).first()
        return won != nil
    }

    private func record(_ sql: any SQLDatabase, tenantID: UUID, weekStart: String, outcome: Outcome) async throws {
        try await sql.raw("""
        UPDATE learned_digest_log SET outcome = \(bind: outcome.rawValue)
        WHERE tenant_id = \(bind: tenantID) AND week_start = \(bind: weekStart)::date
        """).run()
    }

    // MARK: - Calendar

    /// `yyyy-MM-dd` of the local Monday starting this week when `now` is
    /// Sunday 18:00–18:59 in `timezone` (UTC when unknown); nil otherwise.
    static func weekStartIfSendHour(now: Date, timezone: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.weekday, .hour], from: now)
        guard c.weekday == sendWeekday, c.hour == sendHour else { return nil }
        let monday = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        return ProactivePushBudget.localDay(monday, timezone: calendar.timeZone.identifier)
    }
}
