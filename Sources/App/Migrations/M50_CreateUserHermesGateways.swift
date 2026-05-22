import FluentKit

/// HER-241 — per-user Hermes messaging gateway configurations
/// (Telegram, Discord, Slack, WhatsApp, …). Gateway config payload
/// (bot tokens, webhook URLs, app secrets) is sealed via `SecretBox`
/// (AES-GCM, per-tenant HKDF key) into `config_ciphertext` +
/// `config_nonce`. We never echo decrypted config out of the API.
///
/// Hermes itself exposes no admin HTTP endpoint for gateway setup
/// today (only the `hermes gateway setup` CLI). LuminaVaultServer
/// stores the intended config; the user runs the CLI on their Hermes
/// host to apply. `verified_at` is stamped on a successful Hermes
/// `/v1/health` probe; we cannot yet verify per-gateway status.
///
/// FK `ON DELETE CASCADE` to `users.id`. Composite uniqueness on
/// `(tenant_id, gateway_id)` enforces one row per user-per-gateway.
struct M50_CreateUserHermesGateways: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserHermesGateway.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("gateway_id", .string, .required)
            .field("config_ciphertext", .data, .required)
            .field("config_nonce", .data, .required)
            .field("status", .string, .required)
            .field("verified_at", .datetime)
            .field("last_failure_at", .datetime)
            .field("last_failure_code", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "gateway_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserHermesGateway.schema).delete()
    }
}
