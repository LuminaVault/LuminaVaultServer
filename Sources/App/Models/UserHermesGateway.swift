import FluentKit
import Foundation

/// HER-241 — per-tenant row for a configured Hermes messaging gateway
/// (Telegram, Discord, Slack, WhatsApp, …). Plaintext config (bot
/// token, webhook URL, app secret) is sealed via `SecretBox` into
/// `configCiphertext` + `configNonce`. The API never echoes the
/// decrypted blob.
///
/// `status` tracks lifecycle: `not_configured` rows never exist
/// (we only insert on first PUT); after PUT, status is `configured`.
/// `verified_at` is stamped on a successful Hermes `/v1/health`
/// reachability probe via `POST /v1/me/hermes-gateways/{id}/test`.
/// Status can advance to `verified` only when Hermes ships per-gateway
/// status over HTTP (today: not available, so `configured` is terminal).
final class UserHermesGateway: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_hermes_gateways"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "gateway_id") var gatewayID: String
    @Field(key: "config_ciphertext") var configCiphertext: Data
    @Field(key: "config_nonce") var configNonce: Data
    @Field(key: "status") var status: String
    @OptionalField(key: "verified_at") var verifiedAt: Date?
    @OptionalField(key: "last_failure_at") var lastFailureAt: Date?
    @OptionalField(key: "last_failure_code") var lastFailureCode: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
