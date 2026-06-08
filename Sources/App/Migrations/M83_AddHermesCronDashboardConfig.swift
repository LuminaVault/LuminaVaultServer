import FluentKit

/// BYO cron bridge: a tenant's Hermes **dashboard** cron API (`:9119`
/// `/api/cron/jobs`) endpoint + bearer token, so LuminaVault can list/manage a
/// remote (non-container) Hermes's cron jobs. Token sealed via SecretBox like
/// the api_server auth header. Nullable; absent ⇒ no BYO cron source.
struct M83_AddHermesCronDashboardConfig: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .field("cron_dashboard_url", .string)
            .field("cron_dashboard_token_ciphertext", .data)
            .field("cron_dashboard_token_nonce", .data)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .deleteField("cron_dashboard_url")
            .deleteField("cron_dashboard_token_ciphertext")
            .deleteField("cron_dashboard_token_nonce")
            .update()
    }
}
