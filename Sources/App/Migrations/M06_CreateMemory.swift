import FluentKit
import SQLKit

struct M06_CreateMemory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Memory.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("content", .string, .required)
            .field("created_at", .datetime)
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_memories_tenant ON memories (tenant_id)")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Memory.schema).delete()
    }
}
