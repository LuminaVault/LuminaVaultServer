import FluentKit
import SQLKit

/// Evidence-backed, tenant-scoped reasoning graph. PostgreSQL remains the
/// source of truth; recursive CTEs provide bounded graph traversal.
struct M96_CreateKnowledgeGraph: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS knowledge_nodes (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK (kind IN ('claim', 'entity', 'event')),
            canonical_key TEXT NOT NULL,
            label TEXT NOT NULL,
            summary TEXT,
            occurred_at TIMESTAMPTZ,
            confidence DOUBLE PRECISION NOT NULL CHECK (confidence BETWEEN 0 AND 1),
            extractor_provider TEXT,
            extractor_model TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, kind, canonical_key)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS knowledge_edges (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            from_node_id UUID NOT NULL REFERENCES knowledge_nodes(id) ON DELETE CASCADE,
            to_node_id UUID NOT NULL REFERENCES knowledge_nodes(id) ON DELETE CASCADE,
            predicate TEXT NOT NULL CHECK (predicate IN (
                'mentions', 'about', 'supports', 'contradicts', 'causes',
                'precedes', 'related_to', 'derived_from'
            )),
            state TEXT NOT NULL CHECK (state IN ('asserted', 'suggested', 'confirmed', 'dismissed', 'stale')),
            confidence DOUBLE PRECISION NOT NULL CHECK (confidence BETWEEN 0 AND 1),
            rationale TEXT,
            counter_evidence TEXT,
            evidence_fingerprint TEXT NOT NULL,
            review_note TEXT,
            reviewed_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CHECK (from_node_id <> to_node_id),
            UNIQUE (tenant_id, from_node_id, to_node_id, predicate, evidence_fingerprint)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS knowledge_evidence (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            node_id UUID REFERENCES knowledge_nodes(id) ON DELETE CASCADE,
            edge_id UUID REFERENCES knowledge_edges(id) ON DELETE CASCADE,
            memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            source_vault_file_id UUID REFERENCES vault_files(id) ON DELETE SET NULL,
            quote TEXT NOT NULL,
            start_offset INTEGER,
            end_offset INTEGER,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CHECK ((node_id IS NOT NULL) <> (edge_id IS NOT NULL)),
            CHECK (start_offset IS NULL OR start_offset >= 0),
            CHECK (end_offset IS NULL OR end_offset >= start_offset)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS knowledge_extraction_jobs (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            content_fingerprint TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'retry', 'completed')),
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            last_error TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, memory_id, content_fingerprint)
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_nodes_tenant_kind ON knowledge_nodes (tenant_id, kind, updated_at DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_edges_from ON knowledge_edges (tenant_id, from_node_id, state, confidence DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_edges_to ON knowledge_edges (tenant_id, to_node_id, state, confidence DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_evidence_memory ON knowledge_evidence (tenant_id, memory_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_jobs_claim ON knowledge_extraction_jobs (status, next_attempt_at, created_at)").run()
        try await sql.raw("ALTER TABLE insights ADD COLUMN IF NOT EXISTS knowledge_edge_id UUID REFERENCES knowledge_edges(id) ON DELETE SET NULL").run()
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS idx_insights_knowledge_edge ON insights (knowledge_edge_id) WHERE knowledge_edge_id IS NOT NULL").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE insights DROP COLUMN IF EXISTS knowledge_edge_id").run()
        try await sql.raw("DROP TABLE IF EXISTS knowledge_extraction_jobs").run()
        try await sql.raw("DROP TABLE IF EXISTS knowledge_evidence").run()
        try await sql.raw("DROP TABLE IF EXISTS knowledge_edges").run()
        try await sql.raw("DROP TABLE IF EXISTS knowledge_nodes").run()
    }
}
