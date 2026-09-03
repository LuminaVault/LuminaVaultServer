import FluentKit

/// Hermes Mirror — cron jobs mirrored from the tenant's Hermes.
struct M116_CreateHermesMirroredJobs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HermesMirroredJob.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("hermes_job_id", .string, .required)
            .field("name", .string)
            .field("schedule", .string)
            .field("prompt", .string)
            .field("paused", .bool, .required, .sql(.default(false)))
            .field("last_run_at", .datetime)
            .field("next_run_at", .datetime)
            .field("raw", .json, .required)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "hermes_job_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HermesMirroredJob.schema).delete()
    }
}
