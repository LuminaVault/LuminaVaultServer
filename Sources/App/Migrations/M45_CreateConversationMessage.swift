import FluentKit
import SQLKit

/// HER-37 — individual persisted turns within a Conversation. `role`
/// stores the OpenAI-style role string (user|assistant|system).
/// `source_memory_ids` records the memories cited by the assistant on
/// this turn — empty array for user/system turns. Composite index
/// `(conversation_id, created_at)` is the hot path for transcript
/// loads.
struct M45_CreateConversationMessage: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS conversation_messages (
            id UUID PRIMARY KEY,
            conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            source_memory_ids UUID[] NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_conversation_messages_conv_created
            ON conversation_messages (conversation_id, created_at)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS conversation_messages").run()
    }
}
