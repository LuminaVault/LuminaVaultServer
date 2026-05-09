import FluentKit
import Foundation

final class RefreshToken: Model, TenantModel, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, tenantID: UUID, tokenHash: String, expiresAt: Date) {
        self.id = id
        self.tenantID = tenantID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}
