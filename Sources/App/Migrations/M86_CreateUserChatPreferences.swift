import FluentKit

/// Task-based chat Settings preferences shared across iOS and web.
/// Haptics are intentionally not persisted here because they are
/// platform-local behavior.
struct M86_CreateUserChatPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserChatPreference.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("auto_expand_thinking", .bool, .required, .sql(.default(true)))
            .field("send_on_return", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserChatPreference.schema).delete()
    }
}
