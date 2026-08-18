import FluentKit
import SQLKit

/// Per-user inbound MCP tokens. A row is one agent (Claude Code, Codex,
/// Hermes, other) pointed at this account. The plaintext token is never
/// stored — only SHA-256(`token`) — so a dump cannot be replayed against
/// `/v1/mcp`.
struct M113_CreateAgentConnections: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AgentConnection.schema)
            .id()
            .field(
                "tenant_id",
                .uuid,
                .required,
                .references(User.schema, "id", onDelete: .cascade)
            )
            .field("name", .string, .required)
            .field("client_kind", .string, .required)
            .field("token_hash", .data, .required)
            .field("token_prefix", .string, .required)
            .field("created_at", .datetime)
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .unique(on: "token_hash")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                """
                CREATE INDEX IF NOT EXISTS agent_connections_tenant_live_idx
                ON agent_connections (tenant_id)
                WHERE revoked_at IS NULL
                """
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS agent_connections_tenant_live_idx").run()
        }
        try await database.schema(AgentConnection.schema).delete()
    }
}
