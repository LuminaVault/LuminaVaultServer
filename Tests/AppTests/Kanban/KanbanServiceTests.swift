@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Kanban service tests — createBoard→createColumn(x2)→createCard(x2)→snapshot.
/// Verifies columns and cards are sorted by rank, and version increments on
/// each mutation.
///
/// NOTE: These tests require a running Postgres. They are written-but-not-executed
/// per the build policy (HER-310 / `swift build --build-tests` only). Execution
/// happens post-merge against the main dev stack.
@Suite(.serialized)
struct KanbanServiceTests {
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
        let logger = Logger(label: "test.kanban")
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
        await fluent.migrations.add(M29_CreateUserHermesConfig())
        await fluent.migrations.add(M30_AddVaultFileProcessedAt())
        await fluent.migrations.add(M31_CreateUsageMeter())
        await fluent.migrations.add(M32_CreateBillingEventLog())
        await fluent.migrations.add(M33_AddVaultFileMetadata())
        await fluent.migrations.add(M34_AddUserIsAdmin())
        await fluent.migrations.add(M35_AddUsageMeterCharsOut())
        await fluent.migrations.add(M36_AddMemoryGeo())
        await fluent.migrations.add(M37_AddUserVaultInitialized())
        await fluent.migrations.add(M38_AddSpaceCategoryAndCount())
        await fluent.migrations.add(M39_HnswAndTsvector())
        await fluent.migrations.add(M40_CreateIdempotencyKey())
        await fluent.migrations.add(M41_HermesTenantContainers())
        await fluent.migrations.add(M42_AddSkillsStateApnsCategory())
        await fluent.migrations.add(M43_CreateApnsCategoryPrefs())
        await fluent.migrations.add(M44_CreateConversation())
        await fluent.migrations.add(M45_CreateConversationMessage())
        await fluent.migrations.add(M46_CreateUserProviderCredentials())
        await fluent.migrations.add(M47_CreateUserLLMPreferences())
        await fluent.migrations.add(M48_CreateProviderFailoverEvents())
        await fluent.migrations.add(M49_CreateInsight())
        await fluent.migrations.add(M50_CreateUserHermesGateways())
        await fluent.migrations.add(M51_CreateUserHermesProfiles())
        await fluent.migrations.add(M52_AddUserAutoSaveLinks())
        await fluent.migrations.add(M53_AddMemoryReviewState())
        await fluent.migrations.add(M54_CreateKBCompileRejectList())
        await fluent.migrations.add(M55_AddFirstMemoryCompileCompleted())
        await fluent.migrations.add(M56_CreateEmbeddingUsage())
        await fluent.migrations.add(M57_AddModeToLLMPrefs())
        await fluent.migrations.add(M58_AddOnboardingBrainConfigured())
        await fluent.migrations.add(M59_AddSpaceToMemory())
        await fluent.migrations.add(M60_CreateHermesUpdateJob())
        await fluent.migrations.add(M61_CreateImportSessions())
        await fluent.migrations.add(M62_CreatePlugins())
        await fluent.migrations.add(M63_CreateReminder())
        await fluent.migrations.add(M64_CreateProject())
        await fluent.migrations.add(M65_CreateUsageEvents())
        await fluent.migrations.add(M66_AddSkillRunLogOutput())
        await fluent.migrations.add(M67_AddSkillsStateJobFields())
        await fluent.migrations.add(M68_CreateAppleConsent())
        await fluent.migrations.add(M71_CreateKanban())
        // HER-310 — wrap migrate() so transient PG errors shut the pool down
        // before propagating; prevents EventLoopGroupConnectionPool leak and
        // SIGILL on process exit.
        do {
            try await fluent.migrate()
            return fluent
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeUser(_ tenantID: UUID, _ slug: String) -> User {
        User(
            id: tenantID,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-hash-\(slug)",
        )
    }

    private static func makeService(_ fluent: Fluent) -> KanbanService {
        KanbanService(fluent: fluent)
    }

    // MARK: - Tests

    /// createBoard → createColumn(x2) → createCard(x2) → snapshot
    /// Asserts: columns sorted by rank, cards sorted by rank, version
    /// stable across two snapshot reads.
    @Test
    func `snapshot returns columns and cards sorted by rank`() async throws {
        try await Self.withFluent { fluent in
            let tenantID = UUID()
            let slug = "kb\(UUID().uuidString.prefix(4).lowercased())"
            try await Self.makeUser(tenantID, slug).save(on: fluent.db())

            let svc = Self.makeService(fluent)

            // createBoard — version starts at 0
            let board = try await svc.createBoard(tenantID: tenantID, title: "Sprint 1")
            let boardID = try board.requireID()
            #expect(board.version == 0)

            // createColumn x2 — each call bumps version
            let col1 = try await svc.createColumn(tenantID: tenantID, boardID: boardID, title: "Backlog")
            let col2 = try await svc.createColumn(tenantID: tenantID, boardID: boardID, title: "In Progress")
            let col1ID = try col1.requireID()
            let col2ID = try col2.requireID()

            // rank ordering: col1 appended first, col2 after — col1.rank < col2.rank
            #expect(col1.rank < col2.rank, "first column rank must precede second")

            // createCard x2 in col1
            let req1 = CardCreateRequest(columnID: col1ID, title: "Task A")
            let req2 = CardCreateRequest(columnID: col1ID, title: "Task B")
            let card1 = try await svc.createCard(tenantID: tenantID, boardID: boardID, columnID: col1ID, req: req1)
            let card2 = try await svc.createCard(tenantID: tenantID, boardID: boardID, columnID: col1ID, req: req2)
            #expect(card1.rank < card2.rank, "first card rank must precede second")

            // snapshot — columns and cards must be rank-sorted
            let dto = try await svc.snapshot(tenantID: tenantID, boardID: boardID)
            #expect(dto.id == boardID)
            #expect(dto.columns.count == 2)

            let dtoCol1 = try #require(dto.columns.first)
            let dtoCol2 = try #require(dto.columns.last)
            #expect(dtoCol1.id == col1ID)
            #expect(dtoCol2.id == col2ID)
            #expect(dtoCol1.rank < dtoCol2.rank)

            #expect(dtoCol1.cards.count == 2)
            #expect(dtoCol1.cards[0].title == "Task A")
            #expect(dtoCol1.cards[1].title == "Task B")
            #expect(dtoCol1.cards[0].rank < dtoCol1.cards[1].rank)

            // version must be stable across two reads (no mutation between them)
            let v1 = try await svc.version(tenantID: tenantID, boardID: boardID)
            let v2 = try await svc.version(tenantID: tenantID, boardID: boardID)
            #expect(v1 == v2, "version must not change between reads")
            #expect(v1 > 0, "version must have been bumped by mutations")

            // empty second column
            #expect(dtoCol2.cards.isEmpty)

            // moveCard: move card2 to col2
            let moveReq = CardMoveRequest(toColumnID: col2ID)
            let moved = try await svc.moveCard(tenantID: tenantID, cardID: try card2.requireID(), req: moveReq)
            #expect(moved.columnID == col2ID)

            // snapshot again: col1 has 1 card, col2 has 1 card
            let dto2 = try await svc.snapshot(tenantID: tenantID, boardID: boardID)
            let updatedCol1 = try #require(dto2.columns.first(where: { $0.id == col1ID }))
            let updatedCol2 = try #require(dto2.columns.first(where: { $0.id == col2ID }))
            #expect(updatedCol1.cards.count == 1)
            #expect(updatedCol2.cards.count == 1)
            #expect(dto2.version > v1, "version must increment after moveCard")
        }
    }
}
