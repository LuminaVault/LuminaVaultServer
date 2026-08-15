import FluentKit
import SQLKit

/// The real `[[wikilink]]` graph.
///
/// Until now the server never parsed wikilinks. They rode inside the markdown
/// body as text, and `MemoryGraphService`'s `.wikilink` edge kind was actually
/// `memory.source_vault_file_id` — a foreign key to the file a memory came
/// from, not a link the user wrote. So the Brain graph showed lineage while
/// claiming to show links, and backlinks did not exist at all.
///
/// `vault_links` is derived state: one row per `[[link]]` occurrence, rebuilt
/// from source whenever a document is re-indexed. Deleting the whole table and
/// re-indexing reconstructs it exactly.
///
/// `resolution_state` is the interesting column. A link is `resolved` when it
/// names exactly one document, `unresolved` when it names none (a note the user
/// intends to write), and `ambiguous` when the stem matches several — which we
/// record rather than guess, because picking one would draw a wrong edge and
/// cite a wrong file. All three states are useful output: unresolved links are
/// the vault's to-do list, ambiguous ones are a naming problem to fix.
struct M112_CreateVaultLinks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS vault_links (
            link_id BIGSERIAL PRIMARY KEY,
            tenant_id UUID NOT NULL,
            source_vault_file_id UUID NOT NULL REFERENCES vault_files(id) ON DELETE CASCADE,
            source_path TEXT,
            source_line INT NOT NULL,
            raw_target TEXT NOT NULL,
            target_slug TEXT NOT NULL,
            target_heading TEXT,
            label TEXT,
            target_vault_file_id UUID REFERENCES vault_files(id) ON DELETE SET NULL,
            resolved BOOLEAN NOT NULL DEFAULT FALSE,
            resolution_state TEXT NOT NULL DEFAULT 'unresolved',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()

        // Outgoing links for one document, and the delete-then-insert rewrite.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS vault_links_source_idx
        ON vault_links(tenant_id, source_vault_file_id)
        """).run()

        // Backlinks: "what points at this document?" — the query that has never
        // been answerable before.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS vault_links_target_idx
        ON vault_links(tenant_id, target_vault_file_id)
        """).run()

        // Lint's broken-links and ambiguous-links checks scan by state.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS vault_links_state_idx
        ON vault_links(tenant_id, resolution_state)
        """).run()

        // Re-resolution matches pending links against newly created documents
        // by slug, so that lookup must not be a sequential scan.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS vault_links_target_slug_idx
        ON vault_links(tenant_id, target_slug)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS vault_links").run()
    }
}
