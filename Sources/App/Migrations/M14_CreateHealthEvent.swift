import FluentKit
import SQLKit

struct M14_CreateHealthEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HealthEvent.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("event_type", .string, .required)
            .field("value_numeric", .double)
            .field("value_text", .string)
            .field("unit", .string)
            .field("recorded_at", .datetime, .required)
            .field("source", .string)
            .field("metadata", .json)
            .field("created_at", .datetime)
            .create()

        if let sql = database as? any SQLDatabase {
            // Hot path: "last N <event_type> for tenant ordered by time".
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_health_events_tenant_type_recorded
                ON health_events (tenant_id, event_type, recorded_at DESC)
                """).run()
            // Range scans by date alone (cohort-level analytics, ops queries).
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_health_events_tenant_recorded
                ON health_events (tenant_id, recorded_at DESC)
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HealthEvent.schema).delete()
    }
}
