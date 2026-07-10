import FluentKit
import Foundation

final class VaultActivityEvent: Model, @unchecked Sendable {
    static let schema = "vault_activity_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "vault_id") var vaultID: UUID
    @OptionalField(key: "actor_user_id") var actorUserID: UUID?
    @Field(key: "actor_name") var actorName: String
    @Field(key: "action") var action: String
    @Field(key: "target_type") var targetType: String
    @OptionalField(key: "target_id") var targetID: UUID?
    @OptionalField(key: "target_title") var targetTitle: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(vaultID: UUID, actorUserID: UUID?, actorName: String, action: String,
         targetType: String, targetID: UUID? = nil, targetTitle: String? = nil)
    {
        self.vaultID = vaultID
        self.actorUserID = actorUserID
        self.actorName = actorName
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.targetTitle = targetTitle
    }
}
