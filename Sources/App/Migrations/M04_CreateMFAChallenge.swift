import FluentKit
import SQLKit

struct M04_CreateMFAChallenge: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MFAChallenge.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("purpose", .string, .required)
            .field("channel", .string, .required)
            .field("destination", .string, .required)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .field("failed_attempts", .int, .required, .sql(.default(0)))
            .field("resend_count", .int, .required, .sql(.default(0)))
            .field("last_sent_at", .datetime)
            .field("created_at", .datetime)
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_mfa_challenges_tenant ON mfa_challenges (tenant_id)")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MFAChallenge.schema).delete()
    }
}
