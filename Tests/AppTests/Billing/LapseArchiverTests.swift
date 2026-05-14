@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

@Suite(.serialized)
struct LapseArchiverTests {
    fileprivate struct Harness {
        let fluent: Fluent
        let vaultRoot: URL
        let coldRoot: URL
        let job: LapseArchiverJob
    }

    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T,
    ) async throws -> T {
        let suffix = UUID().uuidString
        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-lapse-vault-\(suffix)", isDirectory: true)
        let coldRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-lapse-cold-\(suffix)", isDirectory: true)
        let fluent = Fluent(logger: Logger(label: "test.lapse-archiver"))
        fluent.databases.use(.postgres(configuration: TestPostgres.configuration()), as: .psql)
        await addMigrations(to: fluent)
        try await fluent.migrate()
        try await deletePriorLapseFixtures(fluent)
        let job = LapseArchiverJob(
            fluent: fluent,
            vaultPaths: VaultPathService(rootPath: vaultRoot.path),
            coldStoragePath: coldRoot.path,
            logger: Logger(label: "test.lapse-archiver"),
        )
        do {
            let result = try await body(Harness(fluent: fluent, vaultRoot: vaultRoot, coldRoot: coldRoot, job: job))
            try await fluent.shutdown()
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: coldRoot)
            return result
        } catch {
            try? await fluent.shutdown()
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: coldRoot)
            throw error
        }
    }

    private static func addMigrations(to fluent: Fluent) async {
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
        await fluent.migrations.add(M16_CreateEmailVerificationToken())
        await fluent.migrations.add(M17_CreateOnboardingState())
        await fluent.migrations.add(M18_AddMemoryTags())
        await fluent.migrations.add(M19_CreateSkillsState())
        await fluent.migrations.add(M20_CreateSkillRunLog())
        await fluent.migrations.add(M21_AddMemoryScore())
        await fluent.migrations.add(M22_CreateMemoryArchive())
        await fluent.migrations.add(M23_AddMemorySourceLineage())
        await fluent.migrations.add(M24_AddUserContextRouting())
        await fluent.migrations.add(M25_AddUserPrivacyNoCNOrigin())
        await fluent.migrations.add(M26_AddSkillsStateDailyRunCap())
        await fluent.migrations.add(M27_AddUserTimezone())
        await fluent.migrations.add(M28_CreateAchievementProgress())
        await fluent.migrations.add(M29_CreateUserHermesConfig())
    }

    private static func deletePriorLapseFixtures(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM users WHERE username LIKE 'lapse-%'").run()
    }

    private static func makeUser(
        tier: UserTier,
        expiresAt: Date,
        override: TierOverride = .none,
    ) -> User {
        let slug = "lapse-\(UUID().uuidString.prefix(8).lowercased())"
        return User(
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "x",
            tier: tier.rawValue,
            tierExpiresAt: expiresAt,
            tierOverride: override.rawValue,
        )
    }

    private static func createVaultFile(root: URL, userID: UUID) throws {
        let raw = root
            .appendingPathComponent("tenants", isDirectory: true)
            .appendingPathComponent(userID.uuidString, isDirectory: true)
            .appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: raw.appendingPathComponent("note.md"))
    }

    @Test
    func `expired trial becomes lapsed`() async throws {
        try await Self.withHarness { h in
            let now = Date()
            let user = Self.makeUser(tier: .trial, expiresAt: now.addingTimeInterval(-60))
            try await user.save(on: h.fluent.db())

            let summary = try await h.job.run(now: now)

            #expect(summary.lapsed == 1)
            let reloaded = try #require(try await User.find(user.requireID(), on: h.fluent.db()))
            #expect(reloaded.tier == UserTier.lapsed.rawValue)
        }
    }

    @Test
    func `lapsed ninety days archives and moves vault`() async throws {
        try await Self.withHarness { h in
            let now = Date()
            let user = Self.makeUser(tier: .lapsed, expiresAt: now.addingTimeInterval(-91 * 86400))
            try await user.save(on: h.fluent.db())
            let userID = try user.requireID()
            try Self.createVaultFile(root: h.vaultRoot, userID: userID)

            let summary = try await h.job.run(now: now)

            #expect(summary.archived == 1)
            let reloaded = try #require(try await User.find(userID, on: h.fluent.db()))
            #expect(reloaded.tier == UserTier.archived.rawValue)
            #expect(!FileManager.default.fileExists(atPath: h.vaultRoot.appendingPathComponent("tenants/\(userID.uuidString)").path))
            #expect(FileManager.default.fileExists(atPath: h.coldRoot.appendingPathComponent(userID.uuidString).path))
        }
    }

    @Test
    func `archived after full retention hard deletes row and cold vault`() async throws {
        try await Self.withHarness { h in
            let now = Date()
            let user = Self.makeUser(tier: .archived, expiresAt: now.addingTimeInterval(-366 * 86400))
            try await user.save(on: h.fluent.db())
            let userID = try user.requireID()
            let cold = h.coldRoot.appendingPathComponent(userID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: cold, withIntermediateDirectories: true)
            try Data("cold".utf8).write(to: cold.appendingPathComponent("note.md"))

            let summary = try await h.job.run(now: now)

            #expect(summary.hardDeleted == 1)
            #expect(try await User.find(userID, on: h.fluent.db()) == nil)
            #expect(!FileManager.default.fileExists(atPath: cold.path))
        }
    }

    @Test
    func `archive storage error does not advance tier`() async throws {
        try await Self.withHarness { h in
            let now = Date()
            let user = Self.makeUser(tier: .lapsed, expiresAt: now.addingTimeInterval(-91 * 86400))
            try await user.save(on: h.fluent.db())
            let userID = try user.requireID()
            try Self.createVaultFile(root: h.vaultRoot, userID: userID)
            try FileManager.default.createDirectory(
                at: h.coldRoot.appendingPathComponent(userID.uuidString, isDirectory: true),
                withIntermediateDirectories: true,
            )

            let summary = try await h.job.run(now: now)

            #expect(summary.archived == 0)
            #expect(summary.failures.count == 1)
            let reloaded = try #require(try await User.find(userID, on: h.fluent.db()))
            #expect(reloaded.tier == UserTier.lapsed.rawValue)
        }
    }

    @Test
    func `override users are skipped`() async throws {
        try await Self.withHarness { h in
            let now = Date()
            let user = Self.makeUser(tier: .lapsed, expiresAt: now.addingTimeInterval(-91 * 86400), override: .ultimate)
            try await user.save(on: h.fluent.db())
            #expect(user.tierOverride == TierOverride.ultimate.rawValue)

            let summary = try await h.job.run(now: now)

            #expect(summary.archived == 0)
            let reloaded = try #require(try await User.find(user.requireID(), on: h.fluent.db()))
            #expect(reloaded.tier == UserTier.lapsed.rawValue)
        }
    }
}
