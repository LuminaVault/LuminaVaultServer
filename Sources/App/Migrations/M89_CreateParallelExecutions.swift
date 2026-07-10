import FluentKit
import SQLKit

struct M89_CreateParallelExecutions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        ALTER TABLE router_executions
            ADD COLUMN IF NOT EXISTS conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
            ADD COLUMN IF NOT EXISTS space_id UUID REFERENCES spaces(id) ON DELETE SET NULL,
            ADD COLUMN IF NOT EXISTS prompt TEXT,
            ADD COLUMN IF NOT EXISTS parallel_strategy TEXT,
            ADD COLUMN IF NOT EXISTS participant_count INTEGER NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS synthesized_answer TEXT,
            ADD COLUMN IF NOT EXISTS degraded BOOLEAN NOT NULL DEFAULT FALSE;

        ALTER TABLE conversation_messages
            ADD COLUMN IF NOT EXISTS parallel_execution_id UUID REFERENCES router_executions(id) ON DELETE SET NULL;
        CREATE INDEX IF NOT EXISTS conversation_messages_parallel_execution_idx
            ON conversation_messages(parallel_execution_id);

        CREATE TABLE IF NOT EXISTS router_outputs (
            id UUID PRIMARY KEY,
            execution_id UUID NOT NULL REFERENCES router_executions(id) ON DELETE CASCADE,
            participant_id UUID,
            role TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            stage TEXT NOT NULL,
            round INTEGER NOT NULL,
            content TEXT NOT NULL,
            status TEXT NOT NULL,
            tokens_in BIGINT NOT NULL DEFAULT 0,
            tokens_out BIGINT NOT NULL DEFAULT 0,
            estimated_cost_usd_micros BIGINT NOT NULL DEFAULT 0,
            latency_ms BIGINT NOT NULL DEFAULT 0,
            occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS router_outputs_execution_idx
            ON router_outputs(execution_id, round, occurred_at);

        CREATE TABLE IF NOT EXISTS router_synthesis_presets (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            prompt TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, name)
        );
        CREATE INDEX IF NOT EXISTS router_synthesis_presets_tenant_idx
            ON router_synthesis_presets(tenant_id, updated_at DESC);
        """#).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        DROP TABLE IF EXISTS router_synthesis_presets;
        DROP TABLE IF EXISTS router_outputs;
        DROP INDEX IF EXISTS conversation_messages_parallel_execution_idx;
        ALTER TABLE conversation_messages DROP COLUMN IF EXISTS parallel_execution_id;
        ALTER TABLE router_executions
            DROP COLUMN IF EXISTS degraded,
            DROP COLUMN IF EXISTS synthesized_answer,
            DROP COLUMN IF EXISTS participant_count,
            DROP COLUMN IF EXISTS parallel_strategy,
            DROP COLUMN IF EXISTS prompt,
            DROP COLUMN IF EXISTS space_id,
            DROP COLUMN IF EXISTS conversation_id;
        """#).run()
    }
}
