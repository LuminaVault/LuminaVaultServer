import FluentKit
import SQLKit

/// HER-37 — persistent multi-turn chat threads ("thinking workspace"
/// continuity). One row per Conversation. `space_id` is optional so a
/// conversation can be scoped to a Space or live unfiled.
///
/// Cascade on `tenant_id` deletes a user's conversations + messages
/// transitively (messages.conversation_id ON DELETE CASCADE in M45).
struct M44_CreateConversation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS conversations (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            space_id UUID REFERENCES spaces(id) ON DELETE SET NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_conversations_tenant_updated
            ON conversations (tenant_id, updated_at DESC)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS conversations").run()
    }
}
