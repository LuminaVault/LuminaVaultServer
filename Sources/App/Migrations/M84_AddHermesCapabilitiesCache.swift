import FluentKit

/// P3 — cache the last-probed BYO Hermes `/v1/capabilities` result on the
/// tenant's `user_hermes_config` row so `GET /v1/me/hermes/capabilities`
/// (and the pane-gating clients) don't round-trip to the remote box on
/// every request. `capabilities` is the JSON-encoded `HermesCapabilities`
/// DTO; `capabilities_checked_at` is the probe timestamp for TTL freshness.
/// Both nullable; absent ⇒ never probed.
struct M84_AddHermesCapabilitiesCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .field("capabilities", .string)
            .field("capabilities_checked_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .deleteField("capabilities")
            .deleteField("capabilities_checked_at")
            .update()
    }
}
