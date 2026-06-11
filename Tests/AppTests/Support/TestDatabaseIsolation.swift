import CryptoKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// Per-suite Postgres database isolation so integration `@Suite`s can run in
/// parallel without racing on `_fluent_migrations` or shared table data.
///
/// Each suite gets `t_<hash>` cloned from the base test database (already
/// migrated in CI). `IntegrationDatabaseTrait` activates the suite DB in
/// `prepare(for:)` before every test; `dbTestReader` reads the active name.
enum TestDatabaseIsolation {
    @TaskLocal static var currentDatabase: String?

    /// Base database from env (`hermes_test` on CI). Template source for clones.
    static var baseDatabase: String {
        ProcessInfo.processInfo.environment["POSTGRES_DATABASE"] ?? "hermes_db"
    }

    static var resolvedDatabase: String {
        currentDatabase ?? baseDatabase
    }

    /// Stable, Postgres-safe database name for a suite (max 63 chars).
    static func databaseName(forSuite suiteName: String) -> String {
        let digest = SHA256.hash(data: Data(suiteName.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let suffix = String(hex.prefix(12))
        return "t_\(suffix)"
    }

    /// Extracts the suite component from a Swift Testing qualified name
    /// (`"VaultCRUDTests/createItem()"` → `"VaultCRUDTests"`).
    static func suiteName(from test: Test) -> String {
        let qualified = test.name
        if let slash = qualified.firstIndex(of: "/") {
            return String(qualified[..<slash])
        }
        return qualified
    }

    static func activate(suiteName: String) async throws {
        let database = databaseName(forSuite: suiteName)
        try await IsolationStore.shared.ensureDatabase(database)
        currentDatabase = database
    }
}

// MARK: - Trait

/// Activates an isolated Postgres database for the enclosing suite before each
/// test. Pair with `.tags(.integration)` and use `dbTestReader` / `withTestFluent`.
struct IntegrationDatabaseTrait: SuiteTrait, TestTrait {
    func prepare(for test: Test) async throws {
        try await TestDatabaseIsolation.activate(
            suiteName: TestDatabaseIsolation.suiteName(from: test)
        )
    }
}

extension Trait where Self == IntegrationDatabaseTrait {
    static var integrationDatabase: Self { Self() }
}

// MARK: - Database provisioning

private actor IsolationStore {
    static let shared = IsolationStore()
    private var ready: Set<String> = []

    func ensureDatabase(_ name: String) async throws {
        if ready.contains(name) { return }
        try await provisionIfNeeded(name: name)
        ready.insert(name)
    }

    private func provisionIfNeeded(name: String) async throws {
        if try await databaseExists(name) { return }
        let base = TestDatabaseIsolation.baseDatabase
        if try await databaseExists(base) {
            do {
                try await cloneDatabase(from: base, to: name)
                return
            } catch {
                // Template clone fails when the base DB has open connections (common
                // on first parallel boot). Fall back to empty DB + migrator.
            }
        }
        try await createEmptyDatabase(name)
    }

    private func withAdminSQL<T>(
        _ body: (any SQLDatabase) async throws -> T
    ) async throws -> T {
        let fluent = Fluent(logger: Logger(label: "test.db.isolation"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration(database: "postgres")),
            as: .psql
        )
        defer { try? await fluent.shutdown() }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw IsolationError.noSQLDatabase
        }
        return try await body(sql)
    }

    private func databaseExists(_ name: String) async throws -> Bool {
        try await withAdminSQL { sql in
            let rows = try await sql.raw("""
                SELECT 1 AS one FROM pg_database WHERE datname = \(bind: name)
                """).all()
            return !rows.isEmpty
        }
    }

    private func createEmptyDatabase(_ name: String) async throws {
        try await withAdminSQL { sql in
            try await sql.raw("CREATE DATABASE \(ident: name)").run()
        }
    }

    private func cloneDatabase(from template: String, to name: String) async throws {
        try await withAdminSQL { sql in
            try await sql.raw("""
                CREATE DATABASE \(ident: name) WITH TEMPLATE \(ident: template)
                """).run()
        }
    }
}

private enum IsolationError: Error {
    case noSQLDatabase
}
