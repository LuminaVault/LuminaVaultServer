import FluentKit
import Foundation

/// Per-user APNS / FCM device token. A user may have many devices; sending
/// a push fans out to every active row owned by the tenant.
final class DeviceToken: Model, TenantModel, @unchecked Sendable {
    static let schema = "device_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "token") var token: String
    @Field(key: "platform") var platform: String          // "ios" | "android" | future
    @OptionalField(key: "last_seen_at") var lastSeenAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, token: String, platform: String) {
        self.tenantID = tenantID
        self.token = token
        self.platform = platform
        self.lastSeenAt = Date()
    }
}
