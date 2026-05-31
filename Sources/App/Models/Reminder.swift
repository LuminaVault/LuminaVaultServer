import FluentKit
import Foundation
import LuminaVaultShared

/// HER-Reminders — a user-scheduled timed message. `ReminderScheduler` wakes
/// once per minute, finds rows whose `fireAt` has arrived and `firedAt` is
/// still nil, fires an APNS push (category `reminder`), and stamps `firedAt`.
/// One-shot unless `recurrenceCron` is set, in which case `fireAt` is advanced
/// to the next matching minute and `firedAt` reset so it fires again.
final class Reminder: Model, TenantModel, @unchecked Sendable {
    static let schema = "reminders"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "title") var title: String
    @Field(key: "body") var body: String
    @Field(key: "fire_at") var fireAt: Date
    @OptionalField(key: "recurrence_cron") var recurrenceCron: String?
    @OptionalField(key: "fired_at") var firedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        title: String,
        body: String,
        fireAt: Date,
        recurrenceCron: String? = nil,
        firedAt: Date? = nil,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.recurrenceCron = recurrenceCron
        self.firedAt = firedAt
    }

    func toDTO() throws -> ReminderDTO {
        try ReminderDTO(
            id: requireID(),
            title: title,
            body: body,
            fireAt: fireAt,
            recurrenceCron: recurrenceCron,
            firedAt: firedAt,
            createdAt: createdAt ?? Date(),
        )
    }
}
