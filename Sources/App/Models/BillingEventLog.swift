import FluentKit
import Foundation

final class BillingEventLog: Model, @unchecked Sendable {
    static let schema = "billing_event_logs"

    @ID(key: .id) var id: UUID?
    @Field(key: "event_id") var eventID: String
    @Field(key: "event_type") var eventType: String
    @OptionalField(key: "user_id") var userID: UUID?
    @Timestamp(key: "processed_at", on: .create) var processedAt: Date?

    init() {}

    init(id: UUID? = nil, eventID: String, eventType: String, userID: UUID? = nil) {
        self.id = id
        self.eventID = eventID
        self.eventType = eventType
        self.userID = userID
    }
}
