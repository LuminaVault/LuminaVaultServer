import FluentKit
import Foundation

/// HER-43 (Slice 1) — a tenant's install of a catalog plugin. Per-install
/// config (e.g. a Readwise API token) is sealed via `SecretBox` into
/// `configCiphertext` + `configNonce`; the API never echoes the decrypted
/// blob (list/get carry `hasConfig` only), matching `UserHermesGateway`.
///
/// Unique on `(tenant_id, plugin_slug)`: one install per plugin per tenant.
/// `status` is `enabled` | `disabled`. `last_sync_at` is stamped when a
/// connector install runs a sync.
final class PluginInstall: Model, TenantModel, @unchecked Sendable {
    static let schema = "plugin_installs"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "plugin_slug") var pluginSlug: String
    @Field(key: "status") var status: String
    @Field(key: "config_ciphertext") var configCiphertext: Data
    @Field(key: "config_nonce") var configNonce: Data
    @OptionalField(key: "last_sync_at") var lastSyncAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        pluginSlug: String,
        status: String = PluginInstallState.enabled,
        configCiphertext: Data,
        configNonce: Data,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.pluginSlug = pluginSlug
        self.status = status
        self.configCiphertext = configCiphertext
        self.configNonce = configNonce
    }
}

enum PluginInstallState {
    static let enabled = "enabled"
    static let disabled = "disabled"
}
