import FluentKit

struct M10_CreateDeviceToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DeviceToken.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("token", .string, .required)
            .field("platform", .string, .required)
            .field("last_seen_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(DeviceToken.schema).delete()
    }
}
