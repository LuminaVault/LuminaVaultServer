import FluentKit

struct M12_CreateSpace: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Space.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("slug", .string, .required)
            .field("description", .string)
            .field("color", .string)
            .field("icon", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "slug")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Space.schema).delete()
    }
}
