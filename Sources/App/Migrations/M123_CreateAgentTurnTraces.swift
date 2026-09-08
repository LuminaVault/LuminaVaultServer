import FluentKit
import SQLKit

/// M123 — what the agent actually did on a given turn.
///
/// The system already produces this information and then discards it. Which
/// model answered is computed (`ModelProvenanceDTO`) and delivered on the live
/// response, but never persisted — so `ChatViewModel` can only show a model
/// badge for turns the current device produced, and reopening a thread
/// anywhere else loses it. Which *tools* the model called is never captured at
/// all: `tool_calls` passes through `LLMDTOs`, the adapters and the Gemini
/// translation layer and is dropped.
///
/// That last omission is the important one. Without it the product cannot show
/// that an agent did anything agentic — only that some text came back.
///
/// Column shape deliberately mirrors `router_outputs` (M89), which already
/// records provider/model/tokens/cost/latency for ensemble runs, so the two
/// can be read together by one trace query without translating between shapes.
///
/// `conversation_message_id` is nullable: not every routed call belongs to a
/// conversation turn — skill runs, workflow nodes and one-shot classifier
/// calls all route through the same transport, and their traces are still
/// worth keeping.
///
/// Columns, since the reasoning cannot live in the SQL — `runMigrationScript`
/// splits the script on `;`, so a semicolon inside a `--` comment truncates
/// the statement mid-table. That is not hypothetical: it silently cut this
/// very CREATE TABLE in half on the first run.
///
/// - `tool_calls` — names of the tools the model actually invoked, in call
///   order. An empty array means the turn ran without tools, a real answer,
///   distinct from NULL, which means the response could not be read.
/// - `failover_count` — candidates tried before this one succeeded. Greater
///   than zero means the user's preferred provider failed and we fell over,
///   which today happens entirely silently.
/// - `credential_mode` — `managed` or `byok`, which decides whether the cost
///   column is our money or the user's.
struct M123_CreateAgentTurnTraces: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        CREATE TABLE IF NOT EXISTS agent_turn_traces (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            conversation_message_id UUID REFERENCES conversation_messages(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tool_calls JSONB,
            failover_count INTEGER NOT NULL DEFAULT 0,
            tokens_in BIGINT NOT NULL DEFAULT 0,
            tokens_out BIGINT NOT NULL DEFAULT 0,
            estimated_cost_usd_micros BIGINT NOT NULL DEFAULT 0,
            latency_ms BIGINT NOT NULL DEFAULT 0,
            credential_mode TEXT,
            occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """#, on: sql)
        try await runMigrationScript(
            "CREATE INDEX IF NOT EXISTS agent_turn_traces_message_idx ON agent_turn_traces(conversation_message_id)",
            on: sql
        )
        try await runMigrationScript(
            "CREATE INDEX IF NOT EXISTS agent_turn_traces_tenant_idx ON agent_turn_traces(tenant_id, occurred_at DESC)",
            on: sql
        )
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript("DROP TABLE IF EXISTS agent_turn_traces", on: sql)
    }
}
