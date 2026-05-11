import FluentKit
import Foundation

/// HER-197 — per-tenant override pointing Hermes-backed traffic at a
/// user-hosted gateway. 1:1 with `users` via `tenant_id UNIQUE`. Row
/// absent ⇒ managed default. `auth_header_ciphertext`/`_nonce` are
/// sealed via `SecretBox` (AES-GCM, per-tenant HKDF key); never
/// stored plaintext, never echoed in responses.
///
/// `verified_at` is bumped by `POST /v1/settings/hermes/test` when the
/// configured endpoint replies 2xx to `GET /v1/models` (or `/healthz`).
/// Reset to `nil` on every `PUT` so iOS surfaces the unverified state.
final class UserHermesConfig: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_hermes_config"

    @ID(key: .id) var id: UUID?
    /// FK to `users.id` with `ON DELETE CASCADE` (HER-92 — account
    /// deletion already FK-cascades).
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "base_url") var baseURL: String
    @OptionalField(key: "auth_header_ciphertext") var authHeaderCiphertext: Data?
    @OptionalField(key: "auth_header_nonce") var authHeaderNonce: Data?
    @OptionalField(key: "verified_at") var verifiedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
