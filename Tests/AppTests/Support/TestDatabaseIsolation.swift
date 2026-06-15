import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Synchronization
import Testing

/// Per-suite Postgres database isolation so integration `@Suite`s can run in
/// parallel without racing on `_fluent_migrations` or shared table data.
///
/// Each suite gets `t_<hash>` cloned from the base test database (already
/// migrated in CI). `IntegrationDatabaseTrait.prepare(for:)` runs before each
/// test in the same task, so `@TaskLocal currentDatabase` is visible to
/// `dbTestReader` for the duration of that test.
enum TestDatabaseIsolation {
    /// Active suite for the current test task; set in `IntegrationDatabaseTrait.prepare`.
    @TaskLocal static var activeSuiteName: String?

    /// Isolated DB names keyed by suite (parallel-safe).
    private static let suiteDatabases = Mutex<[String: String]>([:])

    /// Base database from env (`hermes_test` on CI). Template source for clones.
    static var baseDatabase: String {
        ProcessInfo.processInfo.environment["POSTGRES_DATABASE"] ?? "hermes_db"
    }

    static var resolvedDatabase: String {
        if let suite = activeSuiteName,
           let database = suiteDatabases.withLock({ $0[suite] })
        {
            return database
        }
        return baseDatabase
    }

    /// Stable, Postgres-safe database name for a suite (max 63 chars).
    /// FNV-1a — no CryptoKit (Apple-only, breaks Linux CI).
    static func databaseName(forSuite suiteName: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in suiteName.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let suffix = String(format: "%012llx", hash % 0x000f_ffff_ffff_ffff)
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

    /// Provisions (if needed) and registers the isolated database for `suiteName`.
    static func registerDatabase(forSuite suiteName: String) async throws -> String {
        let database = try await prepareDatabase(forSuite: suiteName)
        suiteDatabases.withLock { $0[suiteName] = database }
        return database
    }

    /// Provisions (if needed) and returns the isolated database name for `suiteName`.
    private static func prepareDatabase(forSuite suiteName: String) async throws -> String {
        let database = databaseName(forSuite: suiteName)
        try await IsolationStore.shared.ensureDatabase(database)
        return database
    }
}

// MARK: - Trait

/// Provisions an isolated Postgres database around each test in the suite.
/// Pair with `.tags(.integration)`, `.disabled(if: IntegrationTestEnv.skipIntegration)`,
/// and use `dbTestReader` / `withTestFluent`.
struct IntegrationDatabaseTrait: SuiteTrait, TestTrait, TestScoping {
    typealias TestScopeProvider = IntegrationDatabaseTrait

    func scopeProvider(for _: Test, testCase _: Test.Case?) -> IntegrationDatabaseTrait? {
        self
    }

    func provideScope(
        for test: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let suite = TestDatabaseIsolation.suiteName(from: test)
        _ = try await TestDatabaseIsolation.registerDatabase(forSuite: suite)
        try await TestDatabaseIsolation.$activeSuiteName.withValue(suite) {
            try await function()
        }
    }
}

extension Trait where Self == IntegrationDatabaseTrait {
    static var integrationDatabase: Self {
        Self()
    }
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
        let result: T
        do {
            guard let sql = fluent.db() as? any SQLDatabase else {
                throw IsolationError.noSQLDatabase
            }
            result = try await body(sql)
        } catch {
            try? await fluent.shutdown()
            throw error
        }
        try? await fluent.shutdown()
        return result
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
