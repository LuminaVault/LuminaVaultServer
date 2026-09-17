import FluentKit
import SQLKit

/// Repairs `onboarding_state` rows where the legacy kb-compile latch is set
/// but the memory-compile pair the DTO actually reads is not.
///
/// `M55_AddFirstMemoryCompileCompleted` backfilled `memory ← kb` once, at
/// migration time. Everything that latched afterwards went through
/// `MemoryCompileController`, which wrote **only** the legacy pair, while
/// `OnboardingStateDTO.fromRow` reads `first_memory_compile_completed`. So
/// every user whose first compile happened after M55 shipped reads back as
/// "never compiled".
///
/// That was invisible until the guided-start card shipped. Now it is step 2
/// refusing to complete, and `OnboardingLatches` only self-heals such a row
/// on the *next non-empty* compile — which a user with nothing left to
/// compile can never produce. That is exactly the silent dead end
/// `docs/guided-start.md` warns about, so the repair has to happen here
/// rather than opportunistically.
///
/// Idempotent: the `WHERE` matches nothing on a second run. `COALESCE` keeps
/// the real historical timestamp instead of inventing one.
struct M130_BackfillFirstMemoryCompileFromLegacy: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        UPDATE onboarding_state
           SET first_memory_compile_completed = TRUE,
               first_memory_compile_completed_at =
                 COALESCE(first_memory_compile_completed_at, first_kb_compile_completed_at)
         WHERE first_kb_compile_completed
           AND NOT first_memory_compile_completed
        """).run()
    }

    /// No-op. Reverting would have to guess which rows were repaired here
    /// versus latched normally, and clearing a true latch is worse than
    /// leaving it set.
    func revert(on _: any Database) async throws {}
}
