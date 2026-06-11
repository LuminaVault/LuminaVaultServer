import FluentKit
import Foundation

/// Apple Reminders (EventKit) selective-sync cache — one row per reminder the
/// iOS client has pushed via `POST /v1/reminders/sync`. DISTINCT from the M63
/// `reminders` table (app-scheduled reminders); this is a read cache Hermes
/// queries in the background so `reminders_list` no longer requires a live
/// device-RPC round-trip.
///
/// Upsert key is `(tenant_id, external_id)` where `external_id` is the EventKit
/// `calendarItemIdentifier`. Last-writer-wins on `remote_updated_at` keeps the
/// cache idempotent across overlapping delta pushes. Indexed on
/// `(tenant_id, due_at)` for the "open/overdue, soonest-first" read path.
final class AppleReminder: Model, TenantModel, @unchecked Sendable {
    /// @unchecked Sendable: Fluent property wrappers are not Sendable, but
    /// instances never cross isolation boundaries while mutable — they are
    /// constructed, saved, and discarded within a single request task. Mirrors
    /// `HealthEvent`.
    static let schema = "apple_reminders"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "external_id") var externalID: String
    @Field(key: "title") var title: String
    @OptionalField(key: "notes") var notes: String?
    @OptionalField(key: "due_at") var dueAt: Date?
    @Field(key: "completed") var completed: Bool
    @OptionalField(key: "completed_at") var completedAt: Date?
    @OptionalField(key: "list_name") var listName: String?
    @OptionalField(key: "priority") var priority: Int?
    @OptionalField(key: "remote_updated_at") var remoteUpdatedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        externalID: String,
        title: String,
        notes: String? = nil,
        dueAt: Date? = nil,
        completed: Bool = false,
        completedAt: Date? = nil,
        listName: String? = nil,
        priority: Int? = nil,
        remoteUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.externalID = externalID
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.completed = completed
        self.completedAt = completedAt
        self.listName = listName
        self.priority = priority
        self.remoteUpdatedAt = remoteUpdatedAt
    }
}
