import FluentKit
import Foundation

/// Cross-device chat behavior preferences. Device-local behavior, such as
/// iOS haptics, intentionally stays client-side.
final class UserChatPreference: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_chat_preferences"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "auto_expand_thinking") var autoExpandThinking: Bool
    @Field(key: "send_on_return") var sendOnReturn: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
