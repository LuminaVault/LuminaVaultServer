import FluentKit

/// Creates `user_provider_credential_pool_keys` — additional API keys the
/// credential store round-robins across per provider (Phase 2 item 6,
/// layer 2). FK CASCADE to users so a tenant deletion clears its pool.
struct M77_CreateProviderCredentialPool: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserProviderCredentialPoolKey.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("ciphertext", .data)
            .field("nonce", .data)
            .field("label", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserProviderCredentialPoolKey.schema).delete()
    }
}
