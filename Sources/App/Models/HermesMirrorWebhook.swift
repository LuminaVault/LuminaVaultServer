import FluentKit
import Foundation

/// Hermes Mirror Phase 2 — the tenant's inbound push credential (M121).
///
/// One row per tenant. `token` routes the request and is unique globally;
/// the secret is sealed with the tenant's key and only ever leaves the
/// server once, in the response to a rotate.
final class HermesMirrorWebhook: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_mirror_webhooks"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "token") var token: String
    @Field(key: "secret_ciphertext") var secretCiphertext: Data
    @Field(key: "secret_nonce") var secretNonce: Data
    @Field(key: "rotated_at") var rotatedAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
