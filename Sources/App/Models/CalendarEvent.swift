import FluentKit
import Foundation

/// A cached calendar event synced from an external source into the server so
/// Hermes can reason over the user's schedule in the background (daily briefs,
/// scheduled jobs, proactive nudges) without a live device round-trip.
///
/// `source` discriminates the origin: `"apple_eventkit"` (iOS EventKit
/// selective-sync) or `"google"` (HER-340 Google Calendar OAuth). The upsert
/// key is `(tenant_id, source, external_id)`, so deltas from each source are
/// idempotent and never collide. Cancelled events are tombstoned
/// (`status = "cancelled"`), never hard-deleted, so a re-sync can resurrect a
/// reinstated event and Hermes can still answer "what got cancelled?".
///
/// Last-writer-wins on upsert is driven by `remote_updated_at` (the source's
/// own modification timestamp) — a stale delta never clobbers a fresher row.
final class CalendarEvent: Model, TenantModel, @unchecked Sendable {
    static let schema = "calendar_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    /// `"apple_eventkit"` | `"google"` — origin of the row, part of the upsert key.
    @Field(key: "source") var source: String
    /// Stable per-event id from the source (EventKit `eventIdentifier`,
    /// Google event id). Part of the upsert key.
    @Field(key: "external_id") var externalID: String
    @OptionalField(key: "calendar_id") var calendarID: String?
    @Field(key: "title") var title: String
    @OptionalField(key: "notes") var notes: String?
    @OptionalField(key: "location") var location: String?
    @Field(key: "starts_at") var startsAt: Date
    @Field(key: "ends_at") var endsAt: Date
    @Field(key: "all_day") var allDay: Bool
    /// `"confirmed"` | `"cancelled"`. Cancelled rows are tombstoned, not deleted.
    @Field(key: "status") var status: String
    @OptionalField(key: "organizer") var organizer: String?
    /// Source modification timestamp; drives last-writer-wins on upsert.
    @OptionalField(key: "remote_updated_at") var remoteUpdatedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        source: String,
        externalID: String,
        calendarID: String? = nil,
        title: String,
        notes: String? = nil,
        location: String? = nil,
        startsAt: Date,
        endsAt: Date,
        allDay: Bool = false,
        status: String = "confirmed",
        organizer: String? = nil,
        remoteUpdatedAt: Date? = nil,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.source = source
        self.externalID = externalID
        self.calendarID = calendarID
        self.title = title
        self.notes = notes
        self.location = location
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.status = status
        self.organizer = organizer
        self.remoteUpdatedAt = remoteUpdatedAt
    }
}
