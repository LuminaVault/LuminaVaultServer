@testable import App
import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-30 — covers the `bootstrap-admin` subcommand. Verifies:
///   1. happy path: a new email produces a user with `is_admin=true`
///      and `is_verified=true`, side-effects (HermesProfile, trial)
///      stay consistent with normal signup,
///   2. idempotency: a second invocation finds the existing row and
///      promotes without throwing on `emailExists`,
///   3. missing credentials raise `BootstrapAdminError.missingCredentials`.
@Suite(.serialized)
struct BootstrapAdminCommandTests {
    private static func slug() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }

    private static func reader(
        email: String,
        password: String,
        username: String,
    ) -> ConfigReader {
        ConfigReader(providers: [
            InMemoryProvider(values: [
                "log.level": "warning",
                "postgres.host": cfg(TestPostgres.host),
                "postgres.port": cfg(TestPostgres.port),
                "postgres.database": cfg(TestPostgres.database),
                "postgres.user": cfg(TestPostgres.username),
                "postgres.password": cfg(TestPostgres.password),
                "jwt.hmac.secret": "bootstrap-admin-test-secret-32-chars",
                "jwt.kid": "test-kid",
                "hermes.gatewayKind": "logging",
                "hermes.dataRoot": "/tmp/luminavault-test-hermes",
                "vault.rootPath": "/tmp/luminavault-test",
                "bootstrap.admin.email": cfg(email),
                "bootstrap.admin.password": cfg(password),
                "bootstrap.admin.username": cfg(username),
            ]),
        ])
    }

    private static func ensureSchema() async throws {
        try await runMigrateCommand(reader: ConfigReader(providers: [
            InMemoryProvider(values: [
                "log.level": "warning",
                "postgres.host": cfg(TestPostgres.host),
                "postgres.port": cfg(TestPostgres.port),
                "postgres.database": cfg(TestPostgres.database),
                "postgres.user": cfg(TestPostgres.username),
                "postgres.password": cfg(TestPostgres.password),
            ]),
        ]))
    }

    private static func fetchUser(email: String) async throws -> User? {
        let logger = Logger(label: "test.bootstrap-admin")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        defer { Task { try? await fluent.shutdown() } }
        let user = try await User.query(on: fluent.db())
            .filter(\.$email == email.lowercased())
            .first()
        try await fluent.shutdown()
        return user
    }

    @Test
    func `bootstrap-admin creates a verified admin user`() async throws {
        try await Self.ensureSchema()
        let slug = Self.slug()
        let email = "admin-\(slug)@test.luminavault"
        let username = "admin\(slug)"
        let password = "bootstrap-pass-\(slug)"

        try await runBootstrapAdminCommand(
            reader: Self.reader(email: email, password: password, username: username),
        )

        let row = try await Self.fetchUser(email: email)
        #expect(row != nil, "admin user row should exist after bootstrap-admin")
        #expect(row?.isAdmin == true)
        #expect(row?.isVerified == true)
        #expect(row?.username == username)
        #expect(row?.tier == "trial", "trial defaults should still apply")
    }

    @Test
    func `bootstrap-admin is idempotent`() async throws {
        try await Self.ensureSchema()
        let slug = Self.slug()
        let email = "idem-\(slug)@test.luminavault"
        let username = "idem\(slug)"
        let password = "bootstrap-pass-\(slug)"
        let reader = Self.reader(email: email, password: password, username: username)

        try await runBootstrapAdminCommand(reader: reader)
        try await runBootstrapAdminCommand(reader: reader)

        let row = try await Self.fetchUser(email: email)
        #expect(row?.isAdmin == true)
        #expect(row?.isVerified == true)
    }

    @Test
    func `bootstrap-admin throws when credentials are missing`() async throws {
        try await Self.ensureSchema()
        let reader = ConfigReader(providers: [
            InMemoryProvider(values: [
                "postgres.host": cfg(TestPostgres.host),
                "postgres.port": cfg(TestPostgres.port),
                "postgres.database": cfg(TestPostgres.database),
                "postgres.user": cfg(TestPostgres.username),
                "postgres.password": cfg(TestPostgres.password),
            ]),
        ])
        do {
            try await runBootstrapAdminCommand(reader: reader)
            Issue.record("expected BootstrapAdminError.missingCredentials")
        } catch let err as BootstrapAdminError {
            #expect(err.description.contains("BOOTSTRAP_ADMIN_EMAIL"))
        } catch {
            Issue.record("expected BootstrapAdminError, got \(error)")
        }
    }
}
