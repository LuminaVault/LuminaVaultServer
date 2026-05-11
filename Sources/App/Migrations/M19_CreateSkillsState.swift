import FluentKit
import SQLKit

/// Per-tenant skill runtime state. The manifest itself is filesystem-only
/// (Resources/Skills/<name>/SKILL.md for built-ins; <vaultRoot>/skills/...
/// for user vault skills) — this table tracks only the flags needed to
/// decide whether a skill is enabled, when it last ran, and the override
/// schedule if the user has customized it.
///
/// Primary key is `(tenant_id, source, name)` so a built-in `daily-brief`
/// and a vault `daily-brief` can coexist without collision; `SkillCatalog`
/// applies vault-wins precedence when merging.
struct M19_CreateSkillsState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS skills_state (
                tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                source TEXT NOT NULL CHECK (source IN ('builtin','vault')),
                name TEXT NOT NULL,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                schedule_override TEXT,
                last_run_at TIMESTAMPTZ,
                last_status TEXT,
                last_error TEXT,
                PRIMARY KEY (tenant_id, source, name)
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_skills_state_enabled
            ON skills_state (tenant_id)
            WHERE enabled
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_skills_state_enabled").run()
        try await sql.raw("DROP TABLE IF EXISTS skills_state").run()
    }
}
