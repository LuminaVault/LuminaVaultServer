@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-29 — direct unit tests for the two-phase `HermesProfileService.ensure`
/// contract. The reconciler suite covers admin-level orchestration; these
/// tests pin the service contract itself: idempotency, error-row creation on
/// gateway failure (with the user untouched), recovery from `error`, and the
/// `provisioning -> ready` transition.
@Suite(.serialized)
struct HermesProfileServiceTests {
    private static func withService<T: Sendable>(
        gateway: any HermesGateway,
        _ body: @Sendable (HermesProfileService, Fluent, URL) async throws -> T,
    ) async throws -> T {
        let fluent = try await makeFluent()
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-hps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let vaultPaths = VaultPathService(rootPath: tmpRoot.appendingPathComponent("vault").path)
        let service = HermesProfileService(
            fluent: fluent,
            gateway: gateway,
            vaultPaths: vaultPaths,
        )
        do {
            let result = try await body(service, fluent, tmpRoot)
            try await fluent.shutdown()
            try? FileManager.default.removeItem(at: tmpRoot)
            return result
        } catch {
            try? await fluent.shutdown()
            try? FileManager.default.removeItem(at: tmpRoot)
            throw error
        }
    }

    private static func makeFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.hps"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M02_CreateRefreshToken())
        await fluent.migrations.add(M03_CreatePasswordResetToken())
        await fluent.migrations.add(M04_CreateMFAChallenge())
        await fluent.migrations.add(M05_CreateOAuthIdentity())
        await fluent.migrations.add(M06_CreateMemory())
        await fluent.migrations.add(M07_AddMemoryEmbedding())
        await fluent.migrations.add(M08_CreateHermesProfile())
        await fluent.migrations.add(M09_AddUsernameToUser())
        try await fluent.migrate()
        return fluent
    }

    private static func makeUser(_ slug: String, on db: any Database) async throws -> User {
        let user = User(
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-\(slug)",
        )
        try await user.save(on: db)
        return user
    }

    private static func slug(_ prefix: String) -> String {
        "\(prefix)\(UUID().uuidString.prefix(6).lowercased())"
    }

    @Test
    func `ensure twice returns the same ready row`() async throws {
        let gateway = LoggingHermesGateway(logger: Logger(label: "test.hps.gw"))
        try await Self.withService(gateway: gateway) { service, fluent, _ in
            let user = try await Self.makeUser(Self.slug("idem"), on: fluent.db())
            let first = try await service.ensure(for: user)
            let second = try await service.ensure(for: user)
            #expect(first.id == second.id)
            #expect(second.status == "ready")
            let rows = try await HermesProfile
                .query(on: fluent.db(), tenantID: user.requireID())
                .all()
            #expect(rows.count == 1)
        }
    }

    @Test
    func `gateway failure leaves an error row and user untouched`() async throws {
        let gateway = ThrowingHermesGateway()
        try await Self.withService(gateway: gateway) { service, fluent, _ in
            let user = try await Self.makeUser(Self.slug("fail"), on: fluent.db())
            do {
                _ = try await service.ensure(for: user)
                Issue.record("expected ensure to throw")
            } catch {
                // expected
            }
            let row = try await HermesProfile
                .query(on: fluent.db(), tenantID: user.requireID())
                .first()
            #expect(row?.status == "error")
            #expect(row?.lastError != nil)
            #expect(row?.hermesProfileID.hasPrefix("pending-") == true)
            // User row must still exist — soft-fail contract.
            let stillThere = try await User.find(user.requireID(), on: fluent.db())
            #expect(stillThere != nil)
        }
    }

    @Test
    func `ensure recovers an error row to ready`() async throws {
        let gateway = LoggingHermesGateway(logger: Logger(label: "test.hps.gw"))
        try await Self.withService(gateway: gateway) { service, fluent, _ in
            let user = try await Self.makeUser(Self.slug("recv"), on: fluent.db())
            // Preload an error row simulating a prior failed provision.
            let stale = try HermesProfile(
                tenantID: user.requireID(),
                hermesProfileID: "pending-\(user.requireID().uuidString)",
                status: "error",
            )
            stale.lastError = "boom from a previous attempt"
            try await stale.save(on: fluent.db())

            let healed = try await service.ensure(for: user)
            #expect(healed.status == "ready")
            #expect(healed.lastError == nil)
            #expect(healed.hermesProfileID == "hermes-\(user.username)")
            // Same row reused (no duplicate).
            let rows = try await HermesProfile
                .query(on: fluent.db(), tenantID: user.requireID())
                .all()
            #expect(rows.count == 1)
            #expect(rows.first?.id == stale.id)
        }
    }

    @Test
    func `ensure transitions provisioning row to ready`() async throws {
        let gateway = LoggingHermesGateway(logger: Logger(label: "test.hps.gw"))
        try await Self.withService(gateway: gateway) { service, fluent, _ in
            let user = try await Self.makeUser(Self.slug("prov"), on: fluent.db())
            let stuck = try HermesProfile(
                tenantID: user.requireID(),
                hermesProfileID: "pending-\(user.requireID().uuidString)",
                status: "provisioning",
            )
            try await stuck.save(on: fluent.db())

            let healed = try await service.ensure(for: user)
            #expect(healed.status == "ready")
            #expect(healed.hermesProfileID == "hermes-\(user.username)")
            #expect(healed.id == stuck.id)
        }
    }

    @Test
    func `find returns nil for user without profile`() async throws {
        let gateway = LoggingHermesGateway(logger: Logger(label: "test.hps.gw"))
        try await Self.withService(gateway: gateway) { service, fluent, _ in
            let user = try await Self.makeUser(Self.slug("nope"), on: fluent.db())
            let found = try await service.find(for: user)
            #expect(found == nil)
        }
    }
}

// MARK: - Test doubles

private struct ThrowingHermesGateway: HermesGateway {
    struct GatewayDown: Error, CustomStringConvertible {
        var description: String { "gateway is intentionally down for the test" }
    }

    func provisionProfile(tenantID _: UUID, username _: String) async throws -> String {
        throw GatewayDown()
    }

    func deleteProfile(hermesProfileID _: String) async throws {}
}
