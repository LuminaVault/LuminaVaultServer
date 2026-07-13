import FluentKit
import SQLKit

/// Indexes the two hot paths used by the reasoning engine: tenant-scoped
/// natural-language seed discovery and bounded traversal over active edges.
struct M105_OptimizeKnowledgeReasoning: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_knowledge_nodes_search
        ON knowledge_nodes USING GIN (
            to_tsvector('simple', coalesce(label, '') || ' ' || coalesce(summary, ''))
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_knowledge_edges_active_from
        ON knowledge_edges (tenant_id, from_node_id, confidence DESC)
        WHERE state IN ('asserted', 'suggested', 'confirmed')
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_knowledge_edges_active_to
        ON knowledge_edges (tenant_id, to_node_id, confidence DESC)
        WHERE state IN ('asserted', 'suggested', 'confirmed')
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_evidence_node ON knowledge_evidence (tenant_id, node_id) WHERE node_id IS NOT NULL").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_knowledge_evidence_edge ON knowledge_evidence (tenant_id, edge_id) WHERE edge_id IS NOT NULL").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_knowledge_evidence_edge").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_knowledge_evidence_node").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_knowledge_edges_active_to").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_knowledge_edges_active_from").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_knowledge_nodes_search").run()
    }
}
