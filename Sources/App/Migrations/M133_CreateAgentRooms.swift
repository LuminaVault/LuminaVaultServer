import FluentKit
import SQLKit

/// Agent rooms: one thread where the user and several of their agents
/// (LuminaVault personas, their own Hermes) talk.
///
/// `stop_requested_at` is how the Stop button reaches a chain of agent turns
/// that is already running: the orchestrator re-reads it between turns and
/// ends the chain if it moved past the chain's start.
///
/// `spent_tokens` against `token_budget` is the room's cost cap. Once spent
/// reaches the budget no agent is called again in that room.
struct M133_CreateAgentRooms: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agent_rooms")
            .id()
            .field("tenant_id", .uuid, .required)
            .field("title", .string, .required)
            .field("token_budget", .int, .required, .sql(.default(200_000)))
            .field("spent_tokens", .int, .required, .sql(.default(0)))
            .field("stop_requested_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema("agent_room_members")
            .id()
            .field("room_id", .uuid, .required, .references("agent_rooms", "id", onDelete: .cascade))
            .field("instance_id", .string, .required)
            .field("profile", .string)
            .field("handle", .string, .required)
            .field("display_name", .string, .required)
            .field("respond_mode", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "room_id", "handle")
            .create()

        try await database.schema("agent_room_messages")
            .id()
            .field("room_id", .uuid, .required, .references("agent_rooms", "id", onDelete: .cascade))
            .field("author_kind", .string, .required)
            .field("member_id", .uuid, .references("agent_room_members", "id", onDelete: .setNull))
            .field("body", .string, .required)
            .field("tokens", .int)
            .field("created_at", .datetime)
            .create()

        try await (database as? any SQLDatabase)?.raw("""
        CREATE INDEX IF NOT EXISTS agent_rooms_tenant_idx ON agent_rooms (tenant_id, updated_at DESC)
        """).run()
        try await (database as? any SQLDatabase)?.raw("""
        CREATE INDEX IF NOT EXISTS agent_room_messages_room_idx ON agent_room_messages (room_id, created_at)
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agent_room_messages").delete()
        try await database.schema("agent_room_members").delete()
        try await database.schema("agent_rooms").delete()
    }
}
