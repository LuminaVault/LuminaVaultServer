import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle
import SQLKit

/// The opt-in pre-meeting brief: about half an hour before a meeting, a quiet
/// push saying how many of the user's notes bear on it.
///
/// ## Who and what
/// Once a minute, events that start 25–35 minutes from now, are not all-day
/// and not cancelled, for tenants with `apns_category_prefs.meeting_brief_enabled`
/// (off unless the user turned it on). A ten-minute window ticked every minute
/// means a missed tick or a short restart still catches the event.
///
/// ## Once per event, across replicas
/// Each event is claimed with `INSERT INTO meeting_briefs … ON CONFLICT DO
/// NOTHING RETURNING` *before* any work. Only the replica whose insert landed
/// embeds, searches and pushes, so two replicas ticking the same minute send
/// one push. The row stays whatever the outcome, so an event is looked at
/// once, not on every tick of its window — except when the embedding or the
/// search throws: then nothing was sent and the claim is released, so the next
/// tick retries while the event is still in the window.
///
/// ## Order, after the claim
/// 1. Category gate (`.meeting`, i.e. the opt-in itself, re-read in case it
///    was switched off since the scan) → `opted_out`. No device → `no_device`.
///    Both before the embedding call, which is the only cost here.
/// 2. Embed once, search, keep what passes the floor (`MeetingBriefService`).
///    Nothing passes → `empty`, no push: a brief of loosely related notes is
///    worse than none.
/// 3. Store the matches (the sheet the push opens reads them back), then send.
///
/// ## Not proactive
/// This push answers a meeting the user scheduled and an opt-in they chose,
/// so it never touches `ProactivePushBudget`: it neither spends nor needs the
/// one-a-day proactive slot, and it writes nothing to `proactive_push_log`.
actor MeetingBriefScheduler: Service {
    static let actionCategory = "meeting"
    static let threadID = "meeting"
    static let windowStart: TimeInterval = 25 * 60
    static let windowEnd: TimeInterval = 35 * 60
    /// Events looked at per tick; more simply wait for the next minute.
    static let batchLimit = 200

    static func deepLink(eventID: UUID) -> String {
        "luminavault://meeting/\(eventID.uuidString.lowercased())"
    }

    enum Outcome: String {
        case claimed
        case sent
        case empty
        case optedOut = "opted_out"
        case noDevice = "no_device"
        case failed
    }

    private let fluent: Fluent
    private let push: APNSNotificationService?
    private let briefs: MeetingBriefService
    private let logger: Logger
    private let tickInterval: Duration

    init(
        fluent: Fluent,
        push: APNSNotificationService?,
        briefs: MeetingBriefService,
        logger: Logger,
        tickInterval: Duration = .seconds(60)
    ) {
        self.fluent = fluent
        self.push = push
        self.briefs = briefs
        self.logger = logger
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("meeting.brief scheduler started (tick=\(tickInterval))")
        while !Task.isCancelled {
            do {
                let sent = try await tick(at: Date())
                if sent > 0 {
                    logger.info("meeting.brief tick sent=\(sent)")
                }
            } catch {
                logger.warning("meeting.brief tick error \(error)")
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    private struct Candidate: Decodable {
        let id: UUID
        let tenant_id: UUID
        let title: String
        let notes: String?
        let location: String?
        let starts_at: Date
        let ends_at: Date
        let attendees: String?
        let email: String?
    }

    /// One pass at `now`. Returns how many briefs were pushed. Exposed so
    /// tests drive the clock.
    @discardableResult
    func tick(at now: Date) async throws -> Int {
        guard !fluent.databases.ids().isEmpty else { return 0 }
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }
        let from = now.addingTimeInterval(Self.windowStart)
        let to = now.addingTimeInterval(Self.windowEnd)
        let candidates = try await sql.raw("""
        SELECT e.id, e.tenant_id, e.title, e.notes, e.location, e.starts_at, e.ends_at,
               e.attendees::text AS attendees, u.email
        FROM apns_category_prefs p
        JOIN calendar_events e ON e.tenant_id = p.tenant_id
        JOIN users u ON u.id = p.tenant_id
        WHERE p.meeting_brief_enabled
          AND e.starts_at >= \(bind: from)
          AND e.starts_at <= \(bind: to)
          AND NOT e.all_day
          AND e.status <> 'cancelled'
          AND NOT EXISTS (
              SELECT 1 FROM meeting_briefs b
              WHERE b.tenant_id = e.tenant_id AND b.event_id = e.id
          )
        ORDER BY e.starts_at
        LIMIT \(bind: Self.batchLimit)
        """).all(decoding: Candidate.self)

        var sent = 0
        for candidate in candidates {
            let event = MeetingBriefService.Event(
                id: candidate.id,
                tenantID: candidate.tenant_id,
                title: candidate.title,
                notes: candidate.notes,
                location: candidate.location,
                startsAt: candidate.starts_at,
                endsAt: candidate.ends_at,
                attendees: MeetingBriefService.attendees(fromJSON: candidate.attendees)
            )
            do {
                if try await deliver(sql, event: event, selfEmail: candidate.email, now: now) == .sent {
                    sent += 1
                }
            } catch {
                logger.warning("meeting.brief failed tenant=\(event.tenantID) event=\(event.id): \(error)")
            }
        }
        return sent
    }

    private func deliver(_ sql: any SQLDatabase, event: MeetingBriefService.Event, selfEmail: String?, now: Date) async throws -> Outcome? {
        guard try await claim(sql, event: event, now: now) else { return nil }

        let db = fluent.db()
        if try await APNSNotificationService.isCategorySuppressed(.meeting, tenantID: event.tenantID, on: db) {
            try await record(sql, event: event, outcome: .optedOut)
            return .optedOut
        }
        if try await DeviceToken.query(on: db, tenantID: event.tenantID).count() == 0 {
            try await record(sql, event: event, outcome: .noDevice)
            return .noDevice
        }

        let matches: [MeetingBriefService.Match]
        do {
            matches = try await briefs.matches(for: event, selfEmail: selfEmail)
        } catch {
            // Nothing was sent: let a later tick in the window try again.
            try? await release(sql, event: event)
            throw error
        }
        guard !matches.isEmpty else {
            try await record(sql, event: event, outcome: .empty)
            return .empty
        }

        let rows = try await briefs.memories(tenantID: event.tenantID, ids: matches.map(\.id))
        let mentioned = MeetingBriefService.mentionedNames(
            attendees: event.attendees,
            selfEmail: selfEmail,
            contents: matches.compactMap { rows[$0.id]?.content }
        ).map(\.name)
        try await record(sql, event: event, outcome: .sent, matches: matches, sentAt: now)

        guard let push else { return .sent }
        do {
            try await push.notify(
                userID: event.tenantID,
                title: MeetingBriefService.pushTitle(eventTitle: event.title),
                subtitle: nil,
                body: MeetingBriefService.pushBody(count: matches.count, mentioned: mentioned),
                category: .meeting,
                payload: [
                    "deepLink": Self.deepLink(eventID: event.id),
                    "eventID": event.id.uuidString,
                ],
                interruptionLevel: .passive,
                threadID: Self.threadID,
                actionCategory: Self.actionCategory
            )
            return .sent
        } catch {
            try? await record(sql, event: event, outcome: .failed, matches: matches)
            throw error
        }
    }

    /// `true` when this caller inserted the event's row.
    private func claim(_ sql: any SQLDatabase, event: MeetingBriefService.Event, now: Date) async throws -> Bool {
        struct Won: Decodable { let event_id: UUID }
        let won = try await sql.raw("""
        INSERT INTO meeting_briefs (tenant_id, event_id, claimed_at, outcome)
        VALUES (\(bind: event.tenantID), \(bind: event.id), \(bind: now), \(bind: Outcome.claimed.rawValue))
        ON CONFLICT (tenant_id, event_id) DO NOTHING
        RETURNING event_id
        """).first(decoding: Won.self)
        return won != nil
    }

    private func release(_ sql: any SQLDatabase, event: MeetingBriefService.Event) async throws {
        try await sql.raw("""
        DELETE FROM meeting_briefs
        WHERE tenant_id = \(bind: event.tenantID) AND event_id = \(bind: event.id)
          AND outcome = \(bind: Outcome.claimed.rawValue)
        """).run()
    }

    private func record(
        _ sql: any SQLDatabase,
        event: MeetingBriefService.Event,
        outcome: Outcome,
        matches: [MeetingBriefService.Match]? = nil,
        sentAt: Date? = nil
    ) async throws {
        let json = try matches.flatMap { try String(bytes: JSONEncoder().encode($0), encoding: .utf8) }
        try await sql.raw("""
        UPDATE meeting_briefs
        SET outcome = \(bind: outcome.rawValue),
            memories = COALESCE(\(bind: json)::jsonb, memories),
            sent_at = COALESCE(\(bind: sentAt), sent_at)
        WHERE tenant_id = \(bind: event.tenantID) AND event_id = \(bind: event.id)
        """).run()
    }
}
