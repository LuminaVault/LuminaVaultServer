import FluentKit
import Foundation

final class VaultMembership: Model, @unchecked Sendable {
    static let schema = "vault_memberships"

    @ID(key: .id) var id: UUID?
    @Field(key: "vault_id") var vaultID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "role") var role: String
    @Field(key: "can_use_ai") var canUseAI: Bool
    @Field(key: "created_by_user_id") var createdByUserID: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(vaultID: UUID, userID: UUID, role: String, canUseAI: Bool, createdByUserID: UUID) {
        self.vaultID = vaultID
        self.userID = userID
        self.role = role
        self.canUseAI = canUseAI
        self.createdByUserID = createdByUserID
    }
}
