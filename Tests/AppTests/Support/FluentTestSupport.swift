@testable import App
import HummingbirdFluent
import Logging

/// Runs `body` with a fresh `Fluent` pointed at `TestPostgres` and guarantees
/// shutdown even on throw. Tests that construct `Fluent` directly (instead of
/// going through `buildApplication`) MUST use this helper — the previous
/// `defer { Task { try? await fluent.shutdown() } }` pattern is racy:
/// the `Task` may not run before `Fluent` deinits, which trips the AsyncKit
/// `ConnectionPool.shutdown() was not called before deinit` precondition and
/// aborts the test binary with signal 5.
func withTestFluent<Result>(
    label: String,
    _ body: (Fluent) async throws -> Result,
) async throws -> Result {
    let fluent = Fluent(logger: Logger(label: label))
    fluent.databases.use(
        .postgres(configuration: TestPostgres.configuration()),
        as: .psql,
    )
    do {
        let result = try await body(fluent)
        try await fluent.shutdown()
        return result
    } catch {
        try? await fluent.shutdown()
        throw error
    }
}
