@testable import App
import HummingbirdFluent
import Logging
import Testing

/// Runs `body` with a fresh `Fluent` pointed at `TestPostgres` and guarantees
/// shutdown even on throw. Tests that construct `Fluent` directly (instead of
/// going through `buildApplication`) MUST use this helper — the previous
/// `defer { Task { try? await fluent.shutdown() } }` pattern is racy:
/// the `Task` may not run before `Fluent` deinits, which trips the AsyncKit
/// `ConnectionPool.shutdown() was not called before deinit` precondition and
/// aborts the test binary with signal 5.
/// Records the *reflected* form of an error as a test issue, then leaves the
/// error alone.
///
/// swift-testing reports a thrown error with `String(describing:)`, and
/// PostgresNIO's `PSQLError` deliberately redacts that:
///
///     PSQLError – Generic description to prevent accidental leakage of
///     sensitive data. For debugging details, use `String(reflecting: error)`.
///
/// So a failing integration run says "PSQLError" nineteen times and never says
/// which constraint, table or column objected — which makes the failures
/// untriageable from CI, the only place these tests run.
///
/// This deliberately does **not** wrap or replace the error. Tests match on
/// concrete error types in 213 places; re-throwing a different type to carry a
/// better message would trade one silent failure for another.
func recordErrorDetail(
    _ error: some Error,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let detailed = String(reflecting: error)
    // Only worth recording when reflection actually says more than the
    // description swift-testing will print by itself.
    guard detailed != String(describing: error) else { return }
    Issue.record("underlying error detail: \(detailed)", sourceLocation: sourceLocation)
}

func withTestFluent<Result>(
    label: String,
    _ body: (Fluent) async throws -> Result
) async throws -> Result {
    let fluent = Fluent(logger: Logger(label: label))
    fluent.databases.use(
        .postgres(configuration: TestPostgres.configuration()),
        as: .psql
    )
    do {
        let result = try await body(fluent)
        try await fluent.shutdown()
        return result
    } catch {
        recordErrorDetail(error)
        try? await fluent.shutdown()
        throw error
    }
}

/// Like `withTestFluent`, but builds a harness from `Fluent` first. Guarantees
/// pool shutdown even when `setup` throws (e.g. Postgres down, migrate failure).
func withTestFluentHarness<Result, Harness: Sendable>(
    label: String,
    setup: (Fluent) async throws -> Harness,
    _ body: (Harness) async throws -> Result
) async throws -> Result {
    try await withTestFluent(label: label) { fluent in
        let harness = try await setup(fluent)
        return try await body(harness)
    }
}
