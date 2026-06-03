import FluentKit
import Foundation

/// HER-340 — a single calendar event cached locally for fast schedule
/// context + tool queries, modeled on `HealthEvent` (M14).
///
/// Unified across sources: `source` discriminates `google` |
/// `apple_eventkit` so the Apple/EventKit path can slot in later (Phase 2)
/// with no schema change. `externalID` is the provider's event id; the
/// upsert key is `(tenant_id, source, external_id)` so incremental sync is
/// idempotent. Cancelled events are kept with `status = "cancelled"` (not
/// deleted) so an incremental delta can tombstone them.
///
/// `attendees` and `recurrence` are JSONB via wrapper structs — Fluent's
/// `.json` column does not support top-level Swift arrays, only structs /
/// dictionaries (confirmed regression), hence `CalendarAttendees`.
///
/// Indexed on `(tenant_id, starts_at)` for the dominant "events in window"
/// query. FK `ON DELETE CASCADE` to `users.id`.
final class CalendarEvent: Model, TenantModel, @unchecked Sendable {
    static let schema = "calendar_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "source") var source: String
    @Field(key: "external_id") var externalID: String
    @OptionalField(key: "calendar_id") var calendarID: String?

    @Field(key: "title") var title: String
    @OptionalField(key: "notes") var notes: String?
    @OptionalField(key: "location") var location: String?
    @Field(key: "starts_at") var startsAt: Date
    @Field(key: "ends_at") var endsAt: Date
    @Field(key: "all_day") var allDay: Bool
    @Field(key: "status") var status: String

    @OptionalField(key: "organizer") var organizer: String?
    @OptionalField(key: "attendees") var attendees: CalendarAttendees?
    @OptionalField(key: "recurrence") var recurrence: CalendarRecurrence?
    @OptionalField(key: "html_link") var htmlLink: String?
    @OptionalField(key: "etag") var etag: String?

    @Field(key: "remote_updated_at") var remoteUpdatedAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        source: String = "google",
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
        attendees: CalendarAttendees? = nil,
        recurrence: CalendarRecurrence? = nil,
        htmlLink: String? = nil,
        etag: String? = nil,
        remoteUpdatedAt: Date,
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
        self.attendees = attendees
        self.recurrence = recurrence
        self.htmlLink = htmlLink
        self.etag = etag
        self.remoteUpdatedAt = remoteUpdatedAt
    }
}

/// JSONB wrapper — Fluent `.json` rejects top-level arrays, so attendees
/// are nested under a struct field.
struct CalendarAttendees: Codable, Sendable {
    struct Attendee: Codable, Sendable {
        var email: String?
        var displayName: String?
        var responseStatus: String?
    }

    var list: [Attendee]

    init(list: [Attendee] = []) {
        self.list = list
    }
}

/// JSONB wrapper for RRULE/recurrence rules (Google returns an array of
/// strings); nested to satisfy the same `.json` array limitation.
struct CalendarRecurrence: Codable, Sendable {
    var rules: [String]

    init(rules: [String] = []) {
        self.rules = rules
    }
}
