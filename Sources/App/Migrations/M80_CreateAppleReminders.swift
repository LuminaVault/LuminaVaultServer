import FluentKit
import SQLKit

/// Apple Reminders (EventKit) selective-sync cache. NEW table, DISTINCT from
/// the M63 `reminders` table (app-scheduled reminders) — do not conflate.
struct M80_CreateAppleReminders: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppleReminder.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("external_id", .string, .required)
            .field("title", .string, .required)
            .field("notes", .string)
            .field("due_at", .datetime)
            .field("completed", .bool, .required, .sql(.default(false)))
            .field("completed_at", .datetime)
            .field("list_name", .string)
            .field("priority", .int)
            .field("remote_updated_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "external_id")
            .create()

        if let sql = database as? any SQLDatabase {
            // Hot path: "open/overdue reminders for tenant ordered by due date".
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_apple_reminders_tenant_due
            ON apple_reminders (tenant_id, due_at)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppleReminder.schema).delete()
    }
}
