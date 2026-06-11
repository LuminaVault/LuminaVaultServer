@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// Nous Subscription Integration — `NousOAuthService` orchestration. Uses a
/// real `HermesContainerManager` with a stub DockerExec plus a stub backend
/// so the device-code state machine is driven end-to-end without docker.
@Suite(.serialized)
struct NousOAuthServiceTests {
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

    private static func truncate(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM hermes_tenant_containers").run()
        try await sql.raw("DELETE FROM users WHERE username LIKE 'nous-%'").run()
    }

    private static func makeService(
        fluent: Fluent,
        backend: any NousOAuthBackend
    ) throws -> (NousOAuthService, HermesContainerManager) {
        let docker = StubDockerExec()
        let manager = try HermesContainerManager(
            docker: docker,
            fluent: fluent,
            secretBox: SecretBox(masterKeyBase64: masterKeyBase64),
            config: HermesContainerManager.Config(
                image: "hermes:test",
                network: "lvtest",
                dataRootBase: "/tmp/lvtest",
                portRangeStart: 9200,
                portRangeEnd: 9300,
                idleTTLSeconds: 60
            ),
            logger: Logger(label: "test.nous")
        )
        let service = NousOAuthService(
            containerManager: manager,
            sessionStore: NousOAuthSessionStore(),
            backend: backend,
            fluent: fluent,
            logger: Logger(label: "test.nous.svc")
        )
        return (service, manager)
    }

    @Test
    func `start returns verify URL and session`() async throws {
        try await withTestFluent(label: "lv.test.nous.start") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "nous-start").save(on: fluent.db())

            let backend = StubNousOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let result = try await svc.start(tenantID: tenantID)
            #expect(!result.sessionID.isEmpty)
            #expect(result.verifyURL.contains("nousresearch.com"))
            #expect(result.userCode == "STUB-CODE")

            let calls = await backend.requestCalls
            #expect(calls == [result.sessionID])
        }
    }

    @Test
    func `complete stamps nousConnectedAt without changing tier`() async throws {
        try await withTestFluent(label: "lv.test.nous.complete") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "nous-complete").save(on: fluent.db())

            let backend = StubNousOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let start = try await svc.start(tenantID: tenantID)

            let status = try await svc.complete(sessionID: start.sessionID)
            #expect(status.connected)

            let row = try await HermesTenantContainer.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .first()
            #expect(row?.nousConnectedAt != nil)

            // Nous connect must NOT mutate LuminaVault tier (unlike xAI).
            let user = try await User.find(tenantID, on: fluent.db())
            #expect(user?.tier == "trial")

            let calls = await backend.completeCalls
            #expect(calls == [start.sessionID])
        }
    }

    @Test
    func `complete fails cleanly when backend rejects`() async throws {
        try await withTestFluent(label: "lv.test.nous.complete-fail") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "nous-fail").save(on: fluent.db())

            let backend = StubNousOAuthBackend()
            await backend.setCompletionResult(.success(false))
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let start = try await svc.start(tenantID: tenantID)
            await #expect(throws: NousOAuthError.self) {
                _ = try await svc.complete(sessionID: start.sessionID)
            }

            // No marker on a failed completion.
            let row = try await HermesTenantContainer.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .first()
            #expect(row?.nousConnectedAt == nil)
        }
    }

    @Test
    func `complete with unknown session throws sessionNotFound`() async throws {
        try await withTestFluent(label: "lv.test.nous.unknown") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)
            let backend = StubNousOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            await #expect(throws: NousOAuthError.sessionNotFound) {
                _ = try await svc.complete(sessionID: "does-not-exist")
            }
        }
    }

    @Test
    func `revoke clears nous connection`() async throws {
        try await withTestFluent(label: "lv.test.nous.revoke") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "nous-revoke").save(on: fluent.db())

            let backend = StubNousOAuthBackend()
            let (svc, _) = try Self.makeService(fluent: fluent, backend: backend)
            let start = try await svc.start(tenantID: tenantID)
            _ = try await svc.complete(sessionID: start.sessionID)

            let status = try await svc.revoke(tenantID: tenantID)
            #expect(!status.connected)

            let row = try await HermesTenantContainer.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .first()
            #expect(row?.nousConnectedAt == nil)
            #expect(await backend.revokeCalls == 1)
        }
    }
}
