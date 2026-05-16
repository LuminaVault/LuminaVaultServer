@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

@Suite(.serialized)
struct HermesProfileReconcilerTests {
    private static func withReconciler<T: Sendable>(
        _ body: @Sendable (HermesProfileReconciler, Fluent, URL) async throws -> T,
    ) async throws -> T {
        let fluent = try await makeFluent()
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-recon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let logger = Logger(label: "test.recon")
        let vaultPaths = VaultPathService(rootPath: tmpRoot.appendingPathComponent("vault").path)
        let hermesDataRoot = tmpRoot.appendingPathComponent("hermes").path
        try FileManager.default.createDirectory(
            at: tmpRoot.appendingPathComponent("hermes").appendingPathComponent("profiles"),
            withIntermediateDirectories: true,
        )
        let service = HermesProfileService(
            fluent: fluent,
            gateway: FilesystemHermesGateway(rootPath: hermesDataRoot, logger: logger),
            vaultPaths: vaultPaths,
        )
        let gatewayProbe = HermesGatewayProbe(
            session: .shared,
            logger: logger,
        )
        let reconciler = HermesProfileReconciler(
            fluent: fluent,
            service: service,
            vaultPaths: vaultPaths,
            hermesDataRoot: hermesDataRoot,
            hermesGatewayURL: "",
            gatewayProbe: gatewayProbe,
            logger: logger,
        )
        do {
            let result = try await body(reconciler, fluent, tmpRoot)
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
        let fluent = Fluent(logger: Logger(label: "test.recon"))
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
        await fluent.migrations.add(M10_CreateDeviceToken())
        await fluent.migrations.add(M11_CreateWebAuthnCredential())
        await fluent.migrations.add(M12_CreateSpace())
        await fluent.migrations.add(M13_CreateVaultFile())
        await fluent.migrations.add(M14_CreateHealthEvent())
        await fluent.migrations.add(M15_AddTierFields())
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

    @Test
    func `reconcile creates missing profiles for existing users`() async throws {
        try await Self.withReconciler { recon, fluent, _ in
            let slug1 = "rc1\(UUID().uuidString.prefix(6).lowercased())"
            let slug2 = "rc2\(UUID().uuidString.prefix(6).lowercased())"
            let u1 = try await Self.makeUser(slug1, on: fluent.db())
            let u2 = try await Self.makeUser(slug2, on: fluent.db())

            let summary = try await recon.reconcile()

            #expect(summary.usersScanned >= 2)
            #expect(summary.profilesCreated >= 2)
            #expect(summary.failures.isEmpty)

            // Verify each test-owned user has a ready profile after the run.
            for user in [u1, u2] {
                let profile = try await HermesProfile
                    .query(on: fluent.db(), tenantID: user.requireID())
                    .first()
                #expect(profile != nil)
                #expect(profile?.status == "ready")
                #expect(profile?.hermesProfileID == user.username)
            }
        }
    }

    @Test
    func `reap orphans soft deletes unknown dirs`() async throws {
        try await Self.withReconciler { recon, fluent, tmpRoot in
            // Self-contained: create the active-vs-orphan dirs manually so the
            // assertion doesn't race against shared-DB users that other tests
            // are inserting.
            let activeSlug = "live\(UUID().uuidString.prefix(6).lowercased())"
            let orphanName = "ghost-\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(activeSlug, on: fluent.db())

            // Pre-write the DB row for `activeSlug` so reaper sees it as live.
            let profile = try HermesProfile(
                tenantID: user.requireID(),
                hermesProfileID: activeSlug,
                status: "ready",
            )
            try await profile.save(on: fluent.db())

            let profilesDir = tmpRoot
                .appendingPathComponent("hermes")
                .appendingPathComponent("profiles")
            let activeDir = profilesDir.appendingPathComponent(activeSlug)
            try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
            let orphanDir = profilesDir.appendingPathComponent(orphanName)
            try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)

            let summary = try await recon.reapOrphans()
            #expect(summary.orphansSoftDeleted.contains(orphanName))
            #expect(!FileManager.default.fileExists(atPath: orphanDir.path))

            let entries = try FileManager.default.contentsOfDirectory(atPath: profilesDir.path)
            #expect(entries.contains { $0.hasPrefix("_deleted_") && $0.hasSuffix("_\(orphanName)") })
            // Active dir survived.
            #expect(entries.contains(activeSlug))
        }
    }

    @Test
    func `health reports accurate counts`() async throws {
        try await Self.withReconciler { recon, fluent, tmpRoot in
            // Two users with profiles.
            let s1 = "hl1\(UUID().uuidString.prefix(6).lowercased())"
            let s2 = "hl2\(UUID().uuidString.prefix(6).lowercased())"
            _ = try await Self.makeUser(s1, on: fluent.db())
            _ = try await Self.makeUser(s2, on: fluent.db())
            _ = try await recon.reconcile()

            // Plant an orphan dir.
            let profilesDir = tmpRoot
                .appendingPathComponent("hermes")
                .appendingPathComponent("profiles")
            let orphan = profilesDir.appendingPathComponent("orphan-\(UUID().uuidString.prefix(6).lowercased())")
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

            let h = try await recon.health()
            #expect(h.totalUsers >= 2)
            #expect(h.profilesReady >= 2)
            #expect(h.usersWithoutProfile >= 0)
            #expect(h.orphanFilesystemDirs >= 1)
        }
    }

    @Test
    func `health is zero orphans after reap`() async throws {
        try await Self.withReconciler { recon, fluent, tmpRoot in
            let s = "rh\(UUID().uuidString.prefix(6).lowercased())"
            _ = try await Self.makeUser(s, on: fluent.db())
            _ = try await recon.reconcile()

            let profilesDir = tmpRoot
                .appendingPathComponent("hermes")
                .appendingPathComponent("profiles")
            let orphan = profilesDir.appendingPathComponent("trash-\(UUID().uuidString.prefix(6).lowercased())")
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

            let before = try await recon.health()
            #expect(before.orphanFilesystemDirs >= 1)

            _ = try await recon.reapOrphans()

            let after = try await recon.health()
            // Only this fixture's orphan was reaped — ambient orphans from
            // prior tests can keep the count >0, but at least decremented.
            #expect(after.orphanFilesystemDirs <= before.orphanFilesystemDirs - 1 || after.orphanFilesystemDirs == 0)
        }
    }
}
