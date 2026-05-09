import FluentKit
import SQLKit

struct M03_CreatePasswordResetToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PasswordResetToken.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("failed_attempts", .int, .required, .sql(.default(0)))
            .field("locked_until", .datetime)
            .field("created_at", .datetime)
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_tenant ON password_reset_tokens (tenant_id)")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PasswordResetToken.schema).delete()
    }
}
