import FluentKit

struct M08_CreateHermesProfile: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HermesProfile.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("hermes_profile_id", .string, .required)
            .field("status", .string, .required)
            .field("last_error", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id")              // 1:1 with User
            .unique(on: "hermes_profile_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HermesProfile.schema).delete()
    }
}
