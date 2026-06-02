import FluentKit
import SQLKit

/// M72 Card→Job promotion — adds an `extra` JSONB column to `kanban_cards`.
/// Holds structured promotion config (`CardExtra.job` → `CardJobConfig`:
/// skill_name/source/cron/run_at/domain/prompt/space_id) plus the back-link to
/// the authored job (`job_slug`/`promoted_at`). Nullable: ordinary cards leave
/// it null.
struct M72_AddKanbanCardExtra: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "ALTER TABLE kanban_cards ADD COLUMN IF NOT EXISTS extra JSONB",
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "ALTER TABLE kanban_cards DROP COLUMN IF EXISTS extra",
        ).run()
    }
}
