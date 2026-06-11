import FluentKit
import Foundation

final class OAuthIdentity: Model, TenantModel, @unchecked Sendable {
    static let schema = "oauth_identities"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "provider") var provider: String
    @Field(key: "provider_user_id") var providerUserID: String
    @Field(key: "email") var email: String
    @Field(key: "email_verified") var emailVerified: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        provider: String,
        providerUserID: String,
        email: String,
        emailVerified: Bool
    ) {
        self.id = id
        self.tenantID = tenantID
        self.provider = provider
        self.providerUserID = providerUserID
        self.email = email.lowercased()
        self.emailVerified = emailVerified
    }
}
