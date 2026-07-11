@testable import App
import HummingbirdFluent
import Logging
import Testing

/// Applies the full migration list to the BASE test database
/// (`POSTGRES_DATABASE`). CI runs this suite serially before the parallel
/// integration pass; every per-suite `t_<hash>` database is then cloned from
/// the migrated base via `CREATE DATABASE ... TEMPLATE`, so suites never
/// migrate themselves.
///
/// This is deliberately NOT `.integrationDatabase` — the whole point is to
/// write to the base database, not an isolated clone. (The previous prime
/// filter, `M00EnableExtensionsTests`, carried the isolation trait and only
/// enabled extensions, leaving the base template empty — every clone then
/// failed with undefined-table PSQLErrors.)
/// Disabled in the parallel integration pass (`RUN_INTEGRATION_ONLY=1`):
/// re-running it there would hold connections on the base database, which
/// blocks every concurrent `CREATE DATABASE ... TEMPLATE` clone.
@Suite(
    .serialized,
    .tags(.integration),
    .disabled(if: IntegrationTestEnv.skipIntegration),
    .disabled(if: IntegrationTestEnv.runIntegrationOnly)
)
struct PrimeBaseDatabaseTests {
    @Test
    func `migrate base database`() async throws {
        let fluent = Fluent(logger: Logger(label: "test.prime.base"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration(database: TestDatabaseIsolation.baseDatabase)),
            as: .psql
        )
        do {
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await fluent.shutdown()
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }
}
