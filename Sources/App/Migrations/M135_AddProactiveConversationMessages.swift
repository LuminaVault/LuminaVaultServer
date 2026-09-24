import FluentKit
import SQLKit

/// Muse Chat stage C — messages the assistant sends without being asked.
///
/// `conversation_messages.origin` is `reply` or `proactive`; `source_label`
/// names the sender for the caption above the bubble ("daily-brief"). Both
/// are nullable and every existing row stays `NULL`, which reads as an
/// ordinary reply — so this needs no backfill and no default.
///
/// `conversations.system_key` marks the one thread per tenant that
/// proactive messages land in (`hermie`). A title would do until the user
/// renames the thread; the key survives that. The partial unique index keeps
/// two concurrent deliveries from each creating their own thread.
struct M135_AddProactiveConversationMessages: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE conversation_messages
            ADD COLUMN IF NOT EXISTS origin TEXT NULL,
            ADD COLUMN IF NOT EXISTS source_label TEXT NULL
        """).run()
        try await sql.raw("""
        ALTER TABLE conversations
            ADD COLUMN IF NOT EXISTS system_key TEXT NULL
        """).run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS conversations_tenant_system_key_idx
        ON conversations (tenant_id, system_key)
        WHERE system_key IS NOT NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS conversations_tenant_system_key_idx").run()
        try await sql.raw("ALTER TABLE conversations DROP COLUMN IF EXISTS system_key").run()
        try await sql.raw("""
        ALTER TABLE conversation_messages
            DROP COLUMN IF EXISTS source_label,
            DROP COLUMN IF EXISTS origin
        """).run()
    }
}
