import FluentKit
import Foundation
import LuminaVaultShared

/// Cross-device chat behavior preferences. Device-local behavior, such as
/// iOS haptics, intentionally stays client-side.
final class UserChatPreference: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_chat_preferences"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "auto_expand_thinking") var autoExpandThinking: Bool
    @Field(key: "send_on_return") var sendOnReturn: Bool
    @Field(key: "hybrid_profile") var hybridProfile: String
    @Field(key: "local_fallback_enabled") var localFallbackEnabled: Bool
    @Field(key: "cloud_fallback_enabled") var cloudFallbackEnabled: Bool
    @Field(key: "sync_local_conversations") var syncLocalConversations: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {
        autoExpandThinking = true
        sendOnReturn = false
        hybridProfile = HybridExecutionProfile.balanced.rawValue
        localFallbackEnabled = true
        cloudFallbackEnabled = true
        syncLocalConversations = true
    }
}
