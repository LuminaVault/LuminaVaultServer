import Foundation

/// Process-local one-shot gate around the Fluent migrator.
///
/// The test suite boots `buildApplication` many times in parallel against a
/// single shared Postgres database. Without serialization, concurrent boots
/// both observe an empty `_fluent_migrations`, both INSERT the first migration
/// row, and collide on `uq:_fluent_migrations.name` (sqlState 23505) — failing
/// every racing boot and cascading into the suites that depend on them.
///
/// Neither existing mechanism serializes this:
///   - `@Suite(.serialized)` only orders tests *within* one suite, not across
///     separate suites that run in parallel.
///   - A `@globalActor` lock releases its isolation at every `await`, so two
///     boots interleave *inside* the async migrator.
///
/// This gate memoizes the migration as a single `Task`: the first boot starts
/// it, every other boot awaits that same task. `task` is read and assigned with
/// no `await` in between, so there is no actor-reentrancy window for a second
/// migrator to start. In production `buildApplication` runs once per process,
/// so the gate is an inert pass-through.
actor MigrationGate {
    static let shared = MigrationGate()
    private var tasks: [String: Task<Void, Error>] = [:]

    /// Runs `body` exactly once per `database` key. The first caller for a
    /// given database starts the work; concurrent and later callers await the
    /// same `Task` and observe its result (including a thrown error).
    func migrateOnce(
        database: String,
        _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        let work = tasks[database] ?? Task { try await body() }
        tasks[database] = work
        try await work.value
    }
}
