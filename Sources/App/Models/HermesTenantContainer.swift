import FluentKit
import Foundation

/// HER-240a — persistent metadata for the Hermes container that runs the
/// tenant's xai-oauth session. One row per tenant. `tenant_id UNIQUE`. The
/// row outlives container restarts: the container name + port + encrypted
/// API key are reused on respawn so xai-oauth tokens (which live inside the
/// volume mounted at `/opt/data`) stay associated with the same tenant.
///
/// `api_server_key_ciphertext`/`_nonce` are sealed via the same `SecretBox`
/// HKDF scheme used by `UserHermesConfig` — see `Crypto/SecretBox.swift`.
final class HermesTenantContainer: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_tenant_containers"

    @ID(key: .id) var id: UUID?
    /// FK to `users.id` (every user is a tenant). Unique — one container per tenant.
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "container_name") var containerName: String
    /// Host port the docker run mapped to the container's `API_SERVER_PORT`.
    @Field(key: "port") var port: Int
    @Field(key: "api_server_key_ciphertext") var apiServerKeyCiphertext: Data
    @Field(key: "api_server_key_nonce") var apiServerKeyNonce: Data
    /// `nil` until the user has successfully completed xai-oauth. When set,
    /// the container is exempt from idle eviction.
    @OptionalField(key: "xai_connected_at") var xaiConnectedAt: Date?
    /// `nil` until the user has connected their own Nous Portal subscription
    /// via the OAuth device-code flow. When set, the container is exempt from
    /// idle eviction so the refresh token in `auth.json` on the volume stays
    /// associated with this tenant. Mirrors `xaiConnectedAt`.
    @OptionalField(key: "nous_connected_at") var nousConnectedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// Manually updated by `HermesContainerManager.ensureRunning` on every
    /// touch. Drives `evictIdle()`. Optional rather than `@Timestamp`
    /// because Fluent's `@Timestamp(on: .update)` would fire on every row
    /// write — we want explicit control.
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?

    init() {}

    init(
        tenantID: UUID,
        containerName: String,
        port: Int,
        apiServerKeyCiphertext: Data,
        apiServerKeyNonce: Data,
        xaiConnectedAt: Date? = nil,
        nousConnectedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.tenantID = tenantID
        self.containerName = containerName
        self.port = port
        self.apiServerKeyCiphertext = apiServerKeyCiphertext
        self.apiServerKeyNonce = apiServerKeyNonce
        self.xaiConnectedAt = xaiConnectedAt
        self.nousConnectedAt = nousConnectedAt
        self.lastUsedAt = lastUsedAt
    }
}
