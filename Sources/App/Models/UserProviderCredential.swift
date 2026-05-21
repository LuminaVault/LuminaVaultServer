import FluentKit
import Foundation

/// HER-252 — per-tenant credential row for an external LLM provider.
/// Plaintext (API key, OAuth refresh token) is sealed via `SecretBox`
/// (AES-GCM, per-tenant HKDF key) into `ciphertext` + `nonce`. Providers
/// like Ollama only need `baseURL` and leave the sealed pair `nil`.
///
/// Composite unique constraint `(tenant_id, provider)` is enforced at
/// schema level (see `M46_CreateUserProviderCredentials`).
final class UserProviderCredential: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_provider_credentials"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "provider") var provider: String
    @Field(key: "credential_kind") var credentialKind: String
    @OptionalField(key: "ciphertext") var ciphertext: Data?
    @OptionalField(key: "nonce") var nonce: Data?
    @OptionalField(key: "base_url") var baseURL: String?
    @OptionalField(key: "label") var label: String?
    @OptionalField(key: "verified_at") var verifiedAt: Date?
    @OptionalField(key: "last_failure_at") var lastFailureAt: Date?
    @OptionalField(key: "last_failure_code") var lastFailureCode: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
