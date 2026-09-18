import FluentKit
import SQLKit

/// Ties an assistant turn to the Hermes agent run that produced it.
///
/// When a chat turn escalates, the answer is written by the run watcher once
/// the run finishes, not by the request that started it. Without a link back
/// to the run, that write has no way to tell whether it has already happened
/// — and it can happen twice, because a watcher re-attaches to non-terminal
/// runs after a restart and replays from its cursor. The user would see the
/// same answer twice in their transcript.
///
/// So this is primarily an idempotency key: the watcher looks for an existing
/// assistant message for the run before inserting one.
///
/// It also earns its place on the read side. A client showing a turn that an
/// agent produced can find the run behind it — the tool trail, the approvals,
/// the artifacts — without matching on timestamps or content.
///
/// `NULL` means an ordinary turn, which is every row that exists today and
/// the overwhelming majority of rows that ever will.
struct M129_AddConversationMessageHermesRun: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("conversation_messages")
            .field("hermes_run_id", .uuid)
            .update()
        // Looked up once per finishing run, by exact id. A plain index is
        // enough and stays cheap on a table that is almost entirely NULLs.
        try await (database as? any SQLDatabase)?.raw("""
        CREATE INDEX IF NOT EXISTS conversation_messages_hermes_run_id_idx
        ON conversation_messages (hermes_run_id)
        WHERE hermes_run_id IS NOT NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await (database as? any SQLDatabase)?.raw("""
        DROP INDEX IF EXISTS conversation_messages_hermes_run_id_idx
        """).run()
        try await database.schema("conversation_messages")
            .deleteField("hermes_run_id")
            .update()
    }
}
