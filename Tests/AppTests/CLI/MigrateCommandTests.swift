@testable import App
import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-30 — covers the `migrate` subcommand. Asserts the command:
///   1. completes against a real Postgres without throwing,
///   2. is idempotent (a second run is a no-op),
///   3. leaves the schema queryable (verified via `users.is_admin` column).
@Suite(.serialized)
struct MigrateCommandTests {
    private static func reader() -> ConfigReader {
        ConfigReader(providers: [
            InMemoryProvider(values: [
                "log.level": "warning",
                "postgres.host": cfg(TestPostgres.host),
                "postgres.port": cfg(TestPostgres.port),
                "postgres.database": cfg(TestPostgres.database),
                "postgres.user": cfg(TestPostgres.username),
                "postgres.password": cfg(TestPostgres.password),
            ]),
        ])
    }

    @Test
    func `migrate runs without throwing`() async throws {
        try await runMigrateCommand(reader: Self.reader())
    }

    @Test
    func `migrate is idempotent`() async throws {
        try await runMigrateCommand(reader: Self.reader())
        try await runMigrateCommand(reader: Self.reader())
    }

    @Test
    func `is_admin column exists after migrate`() async throws {
        try await runMigrateCommand(reader: Self.reader())

        let logger = Logger(label: "test.migrate")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        defer { Task { try? await fluent.shutdown() } }

        let sql = (fluent.db() as? any SQLDatabase)
        let row = try await sql?
            .raw(#"SELECT column_name FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'is_admin'"#)
            .first()
        #expect(row != nil, "users.is_admin column should exist after migrate")

        try await fluent.shutdown()
    }
}
