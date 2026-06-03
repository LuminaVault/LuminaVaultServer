import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-340 — syncs one tenant's Google Calendar into the local
/// `CalendarEvent` cache. Incremental when a `syncToken` is stored (Google
/// returns only deltas, incl. cancelled tombstones); otherwise a bounded
/// window list (`windowBack … windowForward`) that mints the first token.
///
/// A `410 Gone` invalidates the token → the service drops it and falls back
/// to a full window re-sync in the same call. Upserts are idempotent on
/// `(tenant_id, source, external_id)`; cancelled deltas flip the local row's
/// `status` to `cancelled` rather than deleting (a later incremental delta
/// could otherwise resurrect a stale row).
struct CalendarSyncService: Sendable {
    static let source = "google"
    let windowBack: TimeInterval = 7 * 24 * 3600
    let windowForward: TimeInterval = 30 * 24 * 3600

    private let fluent: Fluent
    private let tokenStore: CalendarTokenStore
    private let client: GoogleCalendarClient
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        fluent: Fluent,
        tokenStore: CalendarTokenStore,
        client: GoogleCalendarClient,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.fluent = fluent
        self.tokenStore = tokenStore
        self.client = client
        self.logger = logger
        self.now = now
    }

    /// Sync a single tenant. Returns the number of upserted events. No-op
    /// (returns 0) when the account isn't connected / needs reauth.
    @discardableResult
    func sync(tenantID: UUID) async throws -> Int {
        let db = fluent.db()
        guard let account = try await CalendarAccount.query(on: db, tenantID: tenantID)
            .filter(\.$provider == Self.source)
            .first(), account.status == "connected" else {
            return 0
        }

        let accessToken: String
        do {
            accessToken = try await tokenStore.validAccessToken(tenantID: tenantID)
        } catch CalendarTokenStore.Error.needsReauth {
            logger.info("calendar.sync skipped — needs reauth", metadata: ["tenantID": "\(tenantID)"])
            return 0
        }

        let windowStart = now().addingTimeInterval(-windowBack)
        let windowEnd = now().addingTimeInterval(windowForward)

        var upserted = 0
        var syncToken = account.syncToken
        var pageToken: String?
        var newSyncToken: String?
        var attemptedFullResync = false

        repeat {
            let result: GoogleCalendarClient.ListResult
            do {
                result = try await client.listEvents(
                    accessToken: accessToken,
                    syncToken: syncToken,
                    timeMin: syncToken == nil ? windowStart : nil,
                    timeMax: syncToken == nil ? windowEnd : nil,
                    pageToken: pageToken,
                )
            } catch GoogleCalendarClient.Error.syncTokenExpired {
                // Stale token: drop it and restart as a full window sync.
                guard !attemptedFullResync else { throw GoogleCalendarClient.Error.syncTokenExpired }
                attemptedFullResync = true
                syncToken = nil
                pageToken = nil
                continue
            }

            for remote in result.events {
                try await upsert(remote, tenantID: tenantID, on: db)
                upserted += 1
            }

            pageToken = result.nextPageToken
            // `nextSyncToken` only appears on the final page.
            if let token = result.nextSyncToken { newSyncToken = token }
        } while pageToken != nil

        account.syncToken = newSyncToken ?? account.syncToken
        account.lastSyncedAt = now()
        account.windowStart = windowStart
        account.windowEnd = windowEnd
        try await account.save(on: db)
        return upserted
    }

    /// Create an event on Google live, cache it, and return the saved row.
    /// Backs `POST /v1/calendar/events` (the app's explicit Add action).
    func createEvent(
        tenantID: UUID,
        title: String,
        startsAt: Date,
        endsAt: Date,
        location: String?,
        notes: String?,
        attendees: [String],
    ) async throws -> CalendarEvent {
        let accessToken = try await tokenStore.validAccessToken(tenantID: tenantID)
        let remote = try await client.insertEvent(
            accessToken: accessToken,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            location: location,
            notes: notes,
            attendees: attendees,
        )
        let db = fluent.db()
        try await upsert(remote, tenantID: tenantID, on: db)
        guard let saved = try await CalendarEvent.query(on: db, tenantID: tenantID)
            .filter(\.$source == Self.source)
            .filter(\.$externalID == remote.externalID)
            .first() else {
            throw GoogleCalendarClient.Error.malformedResponse
        }
        return saved
    }

    private func upsert(_ remote: GoogleCalendarClient.RemoteEvent, tenantID: UUID, on db: any Database) async throws {
        let existing = try await CalendarEvent.query(on: db, tenantID: tenantID)
            .filter(\.$source == Self.source)
            .filter(\.$externalID == remote.externalID)
            .first()

        let event = existing ?? CalendarEvent(
            tenantID: tenantID,
            source: Self.source,
            externalID: remote.externalID,
            title: remote.title,
            startsAt: remote.startsAt,
            endsAt: remote.endsAt,
            remoteUpdatedAt: remote.updatedAt,
        )
        event.title = remote.title
        event.notes = remote.notes
        event.location = remote.location
        event.startsAt = remote.startsAt
        event.endsAt = remote.endsAt
        event.allDay = remote.allDay
        event.status = remote.cancelled ? "cancelled" : "confirmed"
        event.organizer = remote.organizer
        event.attendees = remote.attendees.isEmpty ? nil : CalendarAttendees(list: remote.attendees)
        event.recurrence = remote.recurrence.isEmpty ? nil : CalendarRecurrence(rules: remote.recurrence)
        event.htmlLink = remote.htmlLink
        event.etag = remote.etag
        event.remoteUpdatedAt = remote.updatedAt
        try await event.save(on: db)
    }
}
