import FluentKit
import SQLKit

/// M71 Native Kanban (MVP) — boards/columns/cards. LuminaVault is the system of
/// record (Hermes has no board API). All tenant-scoped, FK cascade to users.
struct M71_CreateKanban: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KanbanBoard.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("version", .int64, .required, .sql(.default(0)))
            .field("archived_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema(KanbanColumn.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("board_id", .uuid, .required, .references(KanbanBoard.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("rank", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema(KanbanCard.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("board_id", .uuid, .required, .references(KanbanBoard.schema, "id", onDelete: .cascade))
            .field("column_id", .uuid, .required, .references(KanbanColumn.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("body", .string)
            .field("rank", .string, .required)
            .field("priority", .string)
            .field("due_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KanbanCard.schema).delete()
        try await database.schema(KanbanColumn.schema).delete()
        try await database.schema(KanbanBoard.schema).delete()
    }
}
