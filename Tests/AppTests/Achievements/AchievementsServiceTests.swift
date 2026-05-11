@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-196 — service-level tests for `AchievementsService`. Live tests
/// (`record idempotent`, `tenant isolation`) need a running Postgres. Run
/// with `docker compose up -d postgres`. The catalog snapshot test is
/// pure-in-memory and runs without DB.
@Suite(.serialized)
struct AchievementsServiceTests {
    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T,
    ) async throws -> T {
        let fluent = try await makeFluent()
        do {
            let result = try await body(fluent)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeFluent() async throws -> Fluent {
        let logger = Logger(label: "test.achievements")
        let fluent = Fluent(logger: logger)
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
        try await fluent.migrate()
        return fluent
    }

    private static func makeUser(_ id: UUID, _ slug: String) -> User {
        User(
            id: id,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-hash-\(slug)",
        )
    }

    private static func makeService(_ fluent: Fluent) -> AchievementsService {
        AchievementsService(
            fluent: fluent,
            catalog: .current,
            pushService: nil,
            logger: Logger(label: "test.achievements.service"),
        )
    }

    @Test
    func `catalog renders deterministic JSON across runs`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let first = try encoder.encode(AchievementCatalog.current.archetypes)
        let second = try encoder.encode(AchievementCatalog.current.archetypes)
        #expect(first == second, "catalog encoding must be byte-identical across calls")

        // Spot-check structural promises so a future content edit can't
        // silently violate the iOS contract.
        let catalog = AchievementCatalog.current
        #expect(catalog.archetypes.count == 4)
        #expect(catalog.catalogVersion >= 1)
        let archetypeKeys = catalog.archetypes.map(\.key.rawValue).sorted()
        #expect(archetypeKeys == ["lightbringer", "reignmaker", "shadowlord", "soulseeker"])
        for archetype in catalog.archetypes {
            #expect((3 ... 5).contains(archetype.subs.count), "\(archetype.key) sub count must be 3-5")
            for sub in archetype.subs {
                #expect(sub.key.hasPrefix("\(archetype.key.rawValue)."), "sub key must namespace its archetype: \(sub.key)")
                #expect(sub.target >= 1)
            }
        }

        // Every AchievementEvent must be reachable from at least one sub —
        // otherwise the controller-hook fires would land in a dead drop.
        let coveredEvents = Set(catalog.archetypes.flatMap(\.subs).map(\.event))
        #expect(coveredEvents == Set(AchievementEvent.allCases))
    }

    @Test
    func `record is idempotent on unlocked_at after threshold`() async throws {
        try await Self.withFluent { fluent in
            let tenantID = UUID()
            try await Self.makeUser(tenantID, "ach\(UUID().uuidString.prefix(4).lowercased())").save(on: fluent.db())
            let service = Self.makeService(fluent)

            // First crossing — target=1 for `lightbringer.first-spark`.
            let firstUnlock = try await service.record(tenantID: tenantID, event: .memoryUpserted)
            let firstSparkKey = "lightbringer.first-spark"
            #expect(firstUnlock.contains(where: { $0.key == firstSparkKey }))

            let initialRow = try await AchievementProgress.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .filter(\.$achievementKey == firstSparkKey)
                .first()
            try #require(initialRow != nil)
            let initialUnlockedAt = try #require(initialRow?.unlockedAt)

            // Re-fire: counter should keep incrementing but unlocked_at
            // must NOT be rewritten. Newly-unlocked set must not include
            // the same key on a second crossing.
            let second = try await service.record(tenantID: tenantID, event: .memoryUpserted)
            #expect(!second.contains(where: { $0.key == firstSparkKey }), "re-fire must not re-emit \(firstSparkKey)")
            let secondRow = try await AchievementProgress.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .filter(\.$achievementKey == firstSparkKey)
                .first()
            try #require(secondRow != nil)
            #expect(secondRow?.progressCount == 2)
            #expect(secondRow?.unlockedAt == initialUnlockedAt, "unlocked_at must be sticky")
        }
    }

    @Test
    func `record partitions counters by tenant`() async throws {
        try await Self.withFluent { fluent in
            let t1 = UUID()
            let t2 = UUID()
            try await Self.makeUser(t1, "ach\(UUID().uuidString.prefix(4).lowercased())1").save(on: fluent.db())
            try await Self.makeUser(t2, "ach\(UUID().uuidString.prefix(4).lowercased())2").save(on: fluent.db())
            let service = Self.makeService(fluent)

            _ = try await service.record(tenantID: t1, event: .memoryUpserted)
            _ = try await service.record(tenantID: t1, event: .memoryUpserted)
            _ = try await service.record(tenantID: t2, event: .memoryUpserted)

            let firstSparkKey = "lightbringer.first-spark"
            let t1Row = try #require(try await AchievementProgress.query(on: fluent.db())
                .filter(\.$tenantID == t1)
                .filter(\.$achievementKey == firstSparkKey)
                .first())
            let t2Row = try #require(try await AchievementProgress.query(on: fluent.db())
                .filter(\.$tenantID == t2)
                .filter(\.$achievementKey == firstSparkKey)
                .first())
            #expect(t1Row.progressCount == 2)
            #expect(t2Row.progressCount == 1)
            #expect(t1Row.tenantID == t1)
            #expect(t2Row.tenantID == t2)
        }
    }

    @Test
    func `record returns multi-step unlocks when crossing several thresholds`() async throws {
        try await Self.withFluent { fluent in
            let tenantID = UUID()
            try await Self.makeUser(tenantID, "ach\(UUID().uuidString.prefix(4).lowercased())").save(on: fluent.db())
            let service = Self.makeService(fluent)

            // Fire 10 memory upserts — that crosses first-spark (target=1)
            // immediately and kindled-mind (target=10) on the tenth call.
            var unlocked: [String] = []
            for _ in 0 ..< 10 {
                let result = try await service.record(tenantID: tenantID, event: .memoryUpserted)
                unlocked.append(contentsOf: result.map(\.key))
            }
            #expect(unlocked.contains("lightbringer.first-spark"))
            #expect(unlocked.contains("lightbringer.kindled-mind"))
            // No higher-tier sub crosses with only 10 events.
            #expect(!unlocked.contains("lightbringer.illuminator"))
        }
    }
}
