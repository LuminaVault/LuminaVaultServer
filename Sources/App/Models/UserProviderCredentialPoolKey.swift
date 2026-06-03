import FluentKit
import Foundation

/// An additional API key in a provider's round-robin credential pool. The
/// primary key lives in `user_provider_credentials` (1 per provider); pool
/// keys are extras the `UserCredentialStore` rotates across to spread rate
/// limits. Multiple rows per `(tenant_id, provider)` are expected.
final class UserProviderCredentialPoolKey: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_provider_credential_pool_keys"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "provider") var provider: String
    @OptionalField(key: "ciphertext") var ciphertext: Data?
    @OptionalField(key: "nonce") var nonce: Data?
    @OptionalField(key: "label") var label: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
