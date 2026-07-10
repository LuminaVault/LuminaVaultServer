import FluentKit
import Foundation

final class TeamInvitation: Model, @unchecked Sendable {
    static let schema = "team_invitations"

    @ID(key: .id) var id: UUID?
    @Field(key: "team_id") var teamID: UUID
    @Field(key: "email") var email: String
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "vault_grants") var vaultGrants: String
    @Field(key: "invited_by_user_id") var invitedByUserID: UUID
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "accepted_at") var acceptedAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
