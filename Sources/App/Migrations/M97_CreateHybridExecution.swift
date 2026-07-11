import FluentKit

struct M97_CreateHybridExecution: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserChatPreference.schema)
            .field("hybrid_profile", .string, .required, .sql(.default("balanced")))
            .field("local_fallback_enabled", .bool, .required, .sql(.default(true)))
            .field("cloud_fallback_enabled", .bool, .required, .sql(.default(true)))
            .field("sync_local_conversations", .bool, .required, .sql(.default(true)))
            .update()
        try await database.schema(PreparedLocalExecution.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("conversation_id", .uuid, .required, .references(Conversation.schema, "id", onDelete: .cascade))
            .field("messages", .json, .required)
            .field("source_ids", .array(of: .uuid), .required)
            .field("committed_message_id", .uuid, .references(ConversationMessage.schema, "id", onDelete: .setNull))
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
        try await database.schema(MemorySyncTombstone.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("memory_id", .uuid, .required)
            .field("deleted_at", .datetime)
            .unique(on: "tenant_id", "memory_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MemorySyncTombstone.schema).delete()
        try await database.schema(PreparedLocalExecution.schema).delete()
        try await database.schema(UserChatPreference.schema)
            .deleteField("hybrid_profile")
            .deleteField("local_fallback_enabled")
            .deleteField("cloud_fallback_enabled")
            .deleteField("sync_local_conversations")
            .update()
    }
}
