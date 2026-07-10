import FluentKit
import SQLKit

/// Cross-model memory provenance and durable output-indexing outbox.
struct M91_CrossModelMemory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        ALTER TABLE memories
            ADD COLUMN IF NOT EXISTS origin_kind TEXT NOT NULL DEFAULT 'legacy',
            ADD COLUMN IF NOT EXISTS origin_source_id TEXT,
            ADD COLUMN IF NOT EXISTS origin_provider TEXT,
            ADD COLUMN IF NOT EXISTS origin_model TEXT,
            ADD COLUMN IF NOT EXISTS origin_conversation_message_id UUID
                REFERENCES conversation_messages(id) ON DELETE CASCADE;

        CREATE UNIQUE INDEX IF NOT EXISTS memories_origin_source_unique
            ON memories(tenant_id, origin_kind, origin_source_id)
            WHERE origin_source_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS memories_origin_filter_idx
            ON memories(tenant_id, origin_kind, origin_provider, origin_model, created_at DESC);

        CREATE TABLE IF NOT EXISTS memory_contributions (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            operation TEXT NOT NULL,
            actor_kind TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            provider TEXT,
            model TEXT,
            source_reference TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS memory_contributions_memory_time_idx
            ON memory_contributions(memory_id, created_at, id);
        CREATE INDEX IF NOT EXISTS memory_contributions_filter_idx
            ON memory_contributions(tenant_id, provider, model, source_kind, created_at DESC);

        CREATE TABLE IF NOT EXISTS memory_index_jobs (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            source_kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            conversation_message_id UUID REFERENCES conversation_messages(id) ON DELETE CASCADE,
            content TEXT NOT NULL,
            provider TEXT,
            model TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            last_error TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, source_kind, source_id)
        );
        CREATE INDEX IF NOT EXISTS memory_index_jobs_pending_idx
            ON memory_index_jobs(status, next_attempt_at, created_at)
            WHERE status IN ('pending', 'retry');

        ALTER TABLE conversations
            ADD COLUMN IF NOT EXISTS pinned_memory_ids UUID[] NOT NULL DEFAULT '{}',
            ADD COLUMN IF NOT EXISTS route_provider TEXT,
            ADD COLUMN IF NOT EXISTS route_model TEXT;

        INSERT INTO memory_contributions
            (id, tenant_id, memory_id, operation, actor_kind, source_kind, created_at)
        SELECT gen_random_uuid(), tenant_id, id, 'create', 'system', 'legacy', COALESCE(created_at, NOW())
        FROM memories m
        WHERE NOT EXISTS (SELECT 1 FROM memory_contributions c WHERE c.memory_id = m.id);

        INSERT INTO memory_index_jobs
            (id, tenant_id, source_kind, source_id, conversation_message_id, content, status)
        SELECT gen_random_uuid(), c.tenant_id, 'chat', m.id::text, m.id, m.content, 'pending'
        FROM conversation_messages m
        JOIN conversations c ON c.id = m.conversation_id
        WHERE m.role = 'assistant' AND length(trim(m.content)) > 0
        ON CONFLICT (tenant_id, source_kind, source_id) DO NOTHING;
        """#).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        ALTER TABLE conversations
            DROP COLUMN IF EXISTS route_model,
            DROP COLUMN IF EXISTS route_provider,
            DROP COLUMN IF EXISTS pinned_memory_ids;
        DROP TABLE IF EXISTS memory_index_jobs;
        DROP TABLE IF EXISTS memory_contributions;
        DROP INDEX IF EXISTS memories_origin_filter_idx;
        DROP INDEX IF EXISTS memories_origin_source_unique;
        ALTER TABLE memories
            DROP COLUMN IF EXISTS origin_conversation_message_id,
            DROP COLUMN IF EXISTS origin_model,
            DROP COLUMN IF EXISTS origin_provider,
            DROP COLUMN IF EXISTS origin_source_id,
            DROP COLUMN IF EXISTS origin_kind;
        """#).run()
    }
}
