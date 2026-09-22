import FluentKit
import SQLKit

/// Lets an agent-connection key reach the user's Health, Calendar and
/// Reminders over MCP (`health_query`, `calendar_query`, …).
///
/// Every existing key was issued to search a vault, so every existing row
/// gets `false`: turning on health data is the user's explicit choice, per
/// key, never a side effect of upgrading the server.
struct M132_AddAgentConnectionPersonalData: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agent_connections")
            .field("allow_personal_data", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agent_connections")
            .deleteField("allow_personal_data")
            .update()
    }
}
