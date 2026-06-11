@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// HER-240a — `XaiOAuthService` orchestration. Uses a real
/// `HermesContainerManager` with a stub DockerExec plus a stub backend so
/// we can drive the state machine end-to-end without touching docker.
@Suite(.serialized)
struct XaiOAuthServiceTests {
    private static let masterKeyBase64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    private static func makeUser(_ id: UUID, _ slug: String) -> User {
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return User(
            id: id,
            email: "\(slug)-\(suffix)@test.luminavault",
            username: "\(slug)-\(suffix)",
            passwordHash: "stub-hash-\(slug)"
        )
    }

    /// Sweep the rows this suite's helpers create so port allocation +
    /// username uniqueness queries are predictable across reruns.
    private static func truncate(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM hermes_tenant_containers").run()
        try await sql.raw("DELETE FROM users WHERE username LIKE 'her240a-%'").run()
    }

    private static func makeService(
        fluent: Fluent,
        backend: any XaiOAuthBackend
    ) throws -> (XaiOAuthService, HermesContainerManager) {
        let docker = StubDockerExec()
        let manager = try HermesContainerManager(
            docker: docker,
            fluent: fluent,
            secretBox: SecretBox(masterKeyBase64: masterKeyBase64),
            config: HermesContainerManager.Config(
                image: "hermes:test",
                network: "lvtest",
                dataRootBase: "/tmp/lvtest",
                portRangeStart: 9000,
                portRangeEnd: 9100,
                idleTTLSeconds: 60
            ),
            logger: Logger(label: "test.her240a")
        )
        let service = XaiOAuthService(
            containerManager: manager,
            sessionStore: XaiOAuthSessionStore(),
            backend: backend,
            fluent: fluent,
            logger: Logger(label: "test.her240a.svc")
        )
        return (service, manager)
    }

    @Test
    func `start returns authorize URL and session`() async throws {
        try await withTestFluent(label: "lv.test.her240a.start") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-start").save(on: fluent.db())

            let backend = StubXaiOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let result = try await svc.start(tenantID: tenantID)
            #expect(!result.sessionID.isEmpty)
            #expect(result.authorizeURL.hasPrefix("https://accounts.x.ai/"))

            let calls = await backend.requestCalls
            #expect(calls == [result.sessionID])
        }
    }

    @Test
    func `complete forwards callback and promotes user to premium`() async throws {
        try await withTestFluent(label: "lv.test.her240a.complete") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-complete").save(on: fluent.db())

            let backend = StubXaiOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let start = try await svc.start(tenantID: tenantID)

            let callbackURL = "http://127.0.0.1:56121/callback?code=abc&state=xyz"
            let status = try await svc.complete(sessionID: start.sessionID, callbackURL: callbackURL)
            #expect(status.connected)
            #expect(status.tier == "pro")

            let user = try await User.find(tenantID, on: fluent.db())
            #expect(user?.tier == "pro")

            let calls = await backend.submitCalls
            #expect(calls.count == 1)
            #expect(calls.first?.callbackURL == callbackURL)
        }
    }

    @Test
    func `complete fails cleanly when backend rejects`() async throws {
        try await withTestFluent(label: "lv.test.her240a.complete-fail") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-failure").save(on: fluent.db())

            let backend = StubXaiOAuthBackend()
            await MainActor.run {}
            // Simulate Hermes CLI exiting non-zero.
            await withSubmitFailure(backend: backend)
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let start = try await svc.start(tenantID: tenantID)
            await #expect(throws: XaiOAuthError.self) {
                _ = try await svc.complete(sessionID: start.sessionID, callbackURL: "http://127.0.0.1:56121/callback?code=x")
            }

            let user = try await User.find(tenantID, on: fluent.db())
            // Default seeded tier is "trial" via User.init; failure must NOT promote.
            #expect(user?.tier != "pro")
        }
    }

    @Test
    func `complete with unknown session throws sessionNotFound`() async throws {
        try await withTestFluent(label: "lv.test.her240a.unknown-session") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)
            let backend = StubXaiOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            await #expect(throws: XaiOAuthError.sessionNotFound) {
                _ = try await svc.complete(sessionID: "does-not-exist", callbackURL: "http://x/")
            }
        }
    }

    @Test
    func `revoke clears xai connection and demotes tier to free`() async throws {
        try await withTestFluent(label: "lv.test.her240a.revoke") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-revoke").save(on: fluent.db())

            let backend = StubXaiOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let start = try await svc.start(tenantID: tenantID)
            _ = try await svc.complete(sessionID: start.sessionID, callbackURL: "http://127.0.0.1:56121/callback?code=ok")

            let status = try await svc.revoke(tenantID: tenantID)
            #expect(!status.connected)
            #expect(status.tier == "trial")

            let row = try await HermesTenantContainer.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .first()
            #expect(row?.xaiConnectedAt == nil)
            #expect(await backend.revokeCalls == 1)
        }
    }
}

private func withSubmitFailure(backend: StubXaiOAuthBackend) async {
    await backend.setSubmitCallbackResult(.success(false))
}

extension StubXaiOAuthBackend {
    func setSubmitCallbackResult(_ value: Result<Bool, Error>) {
        submitCallbackResult = value
    }
}
