import FluentKit

/// Hermes Mirror — skills mirrored from the tenant's Hermes.
struct M115_CreateHermesMirroredSkills: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HermesMirroredSkill.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("description", .string, .required, .sql(.default("")))
            .field("enabled", .bool, .required, .sql(.default(true)))
            .field("source", .string, .required, .sql(.default("custom")))
            .field("content_hash", .string)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "name")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HermesMirroredSkill.schema).delete()
    }
}
