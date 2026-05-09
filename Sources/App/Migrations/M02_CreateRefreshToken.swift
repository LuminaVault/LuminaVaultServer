import FluentKit
import SQLKit

struct M02_CreateRefreshToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(RefreshToken.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_refresh_tokens_tenant ON refresh_tokens (tenant_id)")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(RefreshToken.schema).delete()
    }
}
