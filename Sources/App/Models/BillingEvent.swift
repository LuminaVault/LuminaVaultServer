import FluentKit
import Foundation

/// Audit / idempotency row for each inbound billing webhook. The
/// `provider_event_id` column has a UNIQUE constraint — if a row with
/// that id already exists the webhook handler returns 200 without
/// reprocessing.
final class BillingEvent: Model, @unchecked Sendable {
    static let schema = "billing_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "provider_event_id") var providerEventId: String
    @Field(key: "provider") var provider: String
    @Field(key: "event_type") var eventType: String
    @OptionalField(key: "user_id") var userId: UUID?
    @Field(key: "raw_payload") var rawPayload: String
    @Field(key: "processed_at") var processedAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        providerEventId: String,
        provider: String = "revenuecat",
        eventType: String,
        userId: UUID?,
        rawPayload: String,
        processedAt: Date = Date()
    ) {
        self.id = id
        self.providerEventId = providerEventId
        self.provider = provider
        self.eventType = eventType
        self.userId = userId
        self.rawPayload = rawPayload
        self.processedAt = processedAt
    }
}
