@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// SelfImprovement service flows that need Postgres + vault/SOUL filesystem.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct SelfImprovementServiceTests {
    private struct Harness: Sendable {
        let service: SelfImprovementService
        let fluent: Fluent
        let soul: SOULService
        let vaultRoot: URL
        let hermesRoot: URL
        let user: User
    }

    private actor StubLLM: HermesLLMService {
        func chat(sessionKey _: String, sessionID _: String?, request _: ChatRequest) async throws -> ChatResponse {
            let message = ChatMessage(role: "assistant", content: #"{"needed":false,"summary":"stable"}"#)
            let raw = HermesUpstreamResponse(
                id: "stub",
                model: "economy-stub",
                choices: [HermesUpstreamChoice(index: 0, message: message, finishReason: "stop")]
            )
            return ChatResponse(id: "stub", model: "economy-stub", message: message, raw: raw)
        }
    }

    private static func withHarness(
        _ body: @Sendable (Harness) async throws -> Void
    ) async throws {
        try await withTestFluentHarness(label: "lv.test.self-improvement", setup: makeHarness) { harness in
            defer {
                try? FileManager.default.removeItem(at: harness.vaultRoot.deletingLastPathComponent())
            }
            try await body(harness)
        }
    }

    private static func makeHarness(fluent: Fluent) async throws -> Harness {
        await registerMigrations(on: fluent)
        try await fluent.migrate()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-si-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tmp.appendingPathComponent("vault")
        let hermesRoot = tmp.appendingPathComponent("hermes")
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)

        let vaultPaths = VaultPathService(rootPath: vaultRoot.path)
        let logger = Logger(label: "test.self-improvement")
        let soul = SOULService(vaultPaths: vaultPaths, hermesDataRoot: hermesRoot.path, logger: logger)
        let catalog = SkillCatalog(vaultPaths: vaultPaths, scanBuiltin: false, logger: logger)
        let service = SelfImprovementService(
            fluent: fluent,
            catalog: catalog,
            vaultPaths: vaultPaths,
            soulService: soul,
            llm: StubLLM(),
            capabilities: nil,
            economyModel: "economy-stub",
            mainModel: "main-stub",
            globallyEnabled: true,
            logger: logger
        )

        let user = User(
            id: UUID(),
            email: "si-\(UUID().uuidString.prefix(6))@test.luminavault",
            username: "si-\(UUID().uuidString.prefix(8).lowercased())",
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        return Harness(
            service: service,
            fluent: fluent,
            soul: soul,
            vaultRoot: vaultRoot,
            hermesRoot: hermesRoot,
            user: user
        )
    }

    private static func writeVaultSkill(tenantID: UUID, name: String, vaultRoot: URL) throws {
        let dir = vaultRoot
            .appendingPathComponent("tenants")
            .appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("skills")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        ---
        name: \(name)
        description: test vault skill
        metadata:
          capability: low
        ---

        Do the thing.
        """
        try body.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test
    func `enqueue curator dry-run queues even when curator disabled`() async throws {
        try await Self.withHarness { h in
            let tenantID = try h.user.requireID()
            let settings = ImprovementSettings(tenantID: tenantID)
            settings.enabled = true
            settings.curatorEnabled = false
            settings.consolidate = false
            try await settings.save(on: h.fluent.db())

            let run = try await h.service.enqueueCurator(for: h.user, trigger: .manual, dryRun: true)
            #expect(run.dryRun)
            #expect(run.status == .queued)
            #expect(run.kind == .curator)

            await #expect(throws: HTTPError.self) {
                _ = try await h.service.enqueueCurator(for: h.user, trigger: .manual, dryRun: false)
            }

            // Avoid leaving a queued run for later tick() claims (shared Postgres).
            if let row = try await ImprovementRun.find(run.id, on: h.fluent.db()) {
                row.status = ImprovementRunStatus.failed.rawValue
                row.failureReason = "test cleanup"
                try await row.save(on: h.fluent.db())
            }
        }
    }

    @Test
    func `setPinned marks vault skill curatorPinned`() async throws {
        try await Self.withHarness { h in
            let tenantID = try h.user.requireID()
            try Self.writeVaultSkill(tenantID: tenantID, name: "pin-me", vaultRoot: h.vaultRoot)

            let dto = try await h.service.setPinned(true, kind: .skill, name: "pin-me", for: h.user)
            #expect(dto.pinned)
            #expect(dto.name == "pin-me")

            let state = try await SkillsState.query(on: h.fluent.db())
                .filter(\.$id == tenantID)
                .filter(\.$name == "pin-me")
                .first()
            #expect(state?.curatorPinned == true)
        }
    }

    @Test
    func `tick dry-run skips pinned skill and applies zero mutations`() async throws {
        try await Self.withHarness { h in
            let tenantID = try h.user.requireID()
            try Self.writeVaultSkill(tenantID: tenantID, name: "pinned-skill", vaultRoot: h.vaultRoot)

            let settings = ImprovementSettings(tenantID: tenantID)
            settings.consolidate = false
            try await settings.save(on: h.fluent.db())

            _ = try await h.service.setPinned(true, kind: .skill, name: "pinned-skill", for: h.user)
            let queued = try await h.service.enqueueCurator(for: h.user, trigger: .manual, dryRun: true)
            #expect(queued.status == .queued)

            // tick() claims one global queued run per call — drain until ours finishes.
            var run = queued
            for _ in 0 ..< 8 {
                await h.service.tick()
                run = try await h.service.run(id: queued.id, for: h.user)
                if run.status != .queued, run.status != .running {
                    break
                }
            }

            #expect(run.status == .succeeded)
            #expect(run.dryRun)
            #expect((run.reportMarkdown ?? "").contains("pinned"))
            #expect(run.actionsApplied == 0)

            let row = try await ImprovementRun.query(on: h.fluent.db())
                .filter(\.$id == queued.id)
                .first()
            #expect(row?.snapshotJSON == nil)
        }
    }

    @Test
    func `decide approve applies SOUL when baseSHA matches`() async throws {
        try await Self.withHarness { h in
            let current = try h.soul.write(for: h.user, body: "# SOUL.md\n\n## Identity\n\nStable voice.\n")
            let proposed = SOULCore.inject(into: "# SOUL.md\n\n## Identity\n\nStable voice.\n\n## Note\n\nTiny tweak.\n")

            let change = ImprovementChange()
            change.tenantID = try h.user.requireID()
            change.kind = ImprovementChangeKind.soul.rawValue
            change.state = ImprovementChangeState.pending.rawValue
            change.trigger = ImprovementTrigger.manual.rawValue
            change.title = "SOUL.md review"
            change.summary = "tiny"
            change.proposedMarkdown = proposed
            change.baseSHA256 = SelfImprovementService.sha256(current)
            try await change.save(on: h.fluent.db())
            let changeID = try change.requireID()

            let dto = try await h.service.decide(changeID: changeID, approve: true, for: h.user)
            #expect(dto.state == .applied)
            #expect(try h.soul.read(for: h.user) == proposed)
        }
    }

    @Test
    func `decide approve marks stale when SOUL changed since review`() async throws {
        try await Self.withHarness { h in
            _ = try h.soul.write(for: h.user, body: "# SOUL.md\n\nOriginal.\n")
            let change = ImprovementChange()
            change.tenantID = try h.user.requireID()
            change.kind = ImprovementChangeKind.soul.rawValue
            change.state = ImprovementChangeState.pending.rawValue
            change.trigger = ImprovementTrigger.manual.rawValue
            change.title = "SOUL.md review"
            change.summary = "stale case"
            change.proposedMarkdown = SOULCore.inject(into: "# SOUL.md\n\nProposed.\n")
            change.baseSHA256 = SelfImprovementService.sha256("not-current")
            try await change.save(on: h.fluent.db())
            let changeID = try change.requireID()

            do {
                _ = try await h.service.decide(changeID: changeID, approve: true, for: h.user)
                Issue.record("expected soul_changed_since_review")
            } catch let error as HTTPError {
                #expect(error.status == .conflict)
            }

            let reloaded = try await ImprovementChange.query(on: h.fluent.db())
                .filter(\.$id == changeID)
                .first()
            #expect(reloaded?.state == ImprovementChangeState.stale.rawValue)
            #expect(try h.soul.read(for: h.user).contains("Original"))
        }
    }

    @Test
    func `decide reject leaves SOUL untouched`() async throws {
        try await Self.withHarness { h in
            let current = try h.soul.write(for: h.user, body: "# SOUL.md\n\nKeep me.\n")
            let change = ImprovementChange()
            change.tenantID = try h.user.requireID()
            change.kind = ImprovementChangeKind.soul.rawValue
            change.state = ImprovementChangeState.pending.rawValue
            change.trigger = ImprovementTrigger.manual.rawValue
            change.title = "SOUL.md review"
            change.summary = "reject"
            change.proposedMarkdown = SOULCore.inject(into: "# SOUL.md\n\nChanged.\n")
            change.baseSHA256 = SelfImprovementService.sha256(current)
            try await change.save(on: h.fluent.db())
            let changeID = try change.requireID()

            let dto = try await h.service.decide(changeID: changeID, approve: false, for: h.user)
            #expect(dto.state == .rejected)
            #expect(try h.soul.read(for: h.user) == current)
        }
    }
}
