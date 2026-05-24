import FluentKit
import SQLKit

/// HER-240 / spec ticket #2 — renames kb-compile → memory-compile.
///
/// Adds new onboarding columns `first_memory_compile_completed` (+ timestamp)
/// and backfills from the existing kb-compile columns so onboarding state is
/// preserved across the rename. The legacy columns are kept this milestone
/// for rollback safety; a follow-up migration drops them after one release
/// cycle once all clients consume the new name.
struct M55_AddFirstMemoryCompileCompleted: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE onboarding_state
        ADD COLUMN IF NOT EXISTS first_memory_compile_completed BOOLEAN NOT NULL DEFAULT FALSE
        """).run()
        try await sql.raw("""
        ALTER TABLE onboarding_state
        ADD COLUMN IF NOT EXISTS first_memory_compile_completed_at TIMESTAMPTZ
        """).run()
        try await sql.raw("""
        UPDATE onboarding_state
        SET first_memory_compile_completed = first_kb_compile_completed,
            first_memory_compile_completed_at = first_kb_compile_completed_at
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE onboarding_state
        DROP COLUMN IF EXISTS first_memory_compile_completed_at
        """).run()
        try await sql.raw("""
        ALTER TABLE onboarding_state
        DROP COLUMN IF EXISTS first_memory_compile_completed
        """).run()
    }
}
