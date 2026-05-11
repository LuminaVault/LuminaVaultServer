import FluentKit
import SQLKit

/// HER-197 — creates `user_hermes_config` (1:1 with `users` via the
/// `tenant_id UNIQUE` constraint) for the BYO Hermes endpoint override.
///
/// `auth_header_ciphertext` + `auth_header_nonce` hold an `AES-GCM`
/// seal (`SecretBox`) of the user's optional bearer token. The
/// migration intentionally stores them as nullable `BYTEA` so a row
/// can exist for a base-URL-only configuration with no token.
///
/// FK `ON DELETE CASCADE` to `users.id` — HER-92 account deletion
/// wipes the row with no extra code.
///
/// Ticket text references `M22_CreateUserHermesConfig`; that number is
/// taken (`M22_CreateMemoryArchive`). Renumbered to M29 to follow
/// M28 (HER-196 achievements, in flight on a sibling branch).
struct M29_CreateUserHermesConfig: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("base_url", .string, .required)
            .field("auth_header_ciphertext", .data)
            .field("auth_header_nonce", .data)
            .field("verified_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema).delete()
    }
}
