import FluentKit
import SQLKit

struct M05_CreateOAuthIdentity: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OAuthIdentity.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("provider_user_id", .string, .required)
            .field("email", .string, .required)
            .field("email_verified", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .unique(on: "provider", "provider_user_id")
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_oauth_identities_tenant ON oauth_identities (tenant_id)")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OAuthIdentity.schema).delete()
    }
}
