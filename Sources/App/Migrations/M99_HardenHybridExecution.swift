import FluentKit
import SQLKit

struct M99_HardenHybridExecution: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PreparedLocalExecution.schema)
            .field("user_message_id", .uuid, .references(ConversationMessage.schema, "id", onDelete: .cascade))
            .update()
        try await database.schema(ConversationMessage.schema)
            .field("local_execution_id", .uuid, .references(PreparedLocalExecution.schema, "id", onDelete: .setNull))
            .unique(on: "local_execution_id")
            .update()
        try await database.schema(Memory.schema)
            .field("updated_at", .datetime)
            .update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE memories SET updated_at = created_at WHERE updated_at IS NULL").run()
            try await sql.raw("CREATE INDEX memories_tenant_updated_id_idx ON memories (tenant_id, updated_at, id)").run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS memories_tenant_updated_id_idx").run()
        }
        try await database.schema(Memory.schema).deleteField("updated_at").update()
        try await database.schema(ConversationMessage.schema).deleteField("local_execution_id").update()
        try await database.schema(PreparedLocalExecution.schema).deleteField("user_message_id").update()
    }
}
