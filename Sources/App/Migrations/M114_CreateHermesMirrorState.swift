import FluentKit

/// Hermes Mirror — per-tenant sync state (one row per tenant).
struct M114_CreateHermesMirrorState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HermesMirrorState.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("last_sync_at", .datetime)
            .field("last_status", .string, .required, .sql(.default("never")))
            .field("last_error", .string)
            .field("skills_count", .int, .required, .sql(.default(0)))
            .field("jobs_count", .int, .required, .sql(.default(0)))
            .field("vault_files_count", .int, .required, .sql(.default(0)))
            .field("vault_path", .string)
            .field("vault_state", .string, .required, .sql(.default("absent")))
            .field("vault_cursor", .string)
            .field("sessions_cursor", .string)
            .field("sessions_imported", .int, .required, .sql(.default(0)))
            .field("compile_job_id", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HermesMirrorState.schema).delete()
    }
}
