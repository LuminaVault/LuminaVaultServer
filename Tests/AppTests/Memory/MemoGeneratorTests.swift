import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import App

/// Drives `MemoGeneratorService` against a scripted Hermes transport so we
/// can verify: agent loop terminates, citations parse, memo body is shaped
/// correctly, and `save=true` lands a `vault_files` row + on-disk file.
@Suite(.serialized)
struct MemoGeneratorTests {

    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent, URL) async throws -> T
    ) async throws -> T {
        let fluent = try await makeFluent()
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-memo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        do {
            let result = try await body(fluent, tmpRoot)
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
        let fluent = Fluent(logger: Logger(label: "test.memo"))
        fluent.databases.use(
            .postgres(configuration: .init(
                hostname: "127.0.0.1", port: 5433,
                username: "hermes", password: "luminavault",
                database: "hermes_db", tls: .disable
            )),
            as: .psql
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
        try await fluent.migrate()
        return fluent
    }

    private static func makeService(fluent: Fluent, tmpRoot: URL, transport: any HermesChatTransport) -> MemoGeneratorService {
        MemoGeneratorService(
            transport: transport,
            memories: MemoryRepository(fluent: fluent),
            embeddings: DeterministicEmbeddingService(),
            vaultPaths: VaultPathService(rootPath: tmpRoot.appendingPathComponent("vault").path),
            fluent: fluent,
            defaultModel: "test-model",
            logger: Logger(label: "test.memo")
        )
    }

    private static func makeTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "memo-\(UUID().uuidString.prefix(6).lowercased())@test.luminavault",
            username: "memo-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        return id
    }

    @Test
    func memoLoopTerminatesAndPersistsToVault() async throws {
        try await Self.withFluent { fluent, tmpRoot in
            let tenantID = try await Self.makeTenant(on: fluent)
            // Seed two memories so session_search has something to find.
            let repo = MemoryRepository(fluent: fluent)
            let embedder = DeterministicEmbeddingService()
            _ = try await repo.create(
                tenantID: tenantID,
                content: "morning drink: jasmine tea, never coffee",
                embedding: try await embedder.embed("morning drink: jasmine tea, never coffee")
            )
            _ = try await repo.create(
                tenantID: tenantID,
                content: "evening drink: chamomile tea before bed",
                embedding: try await embedder.embed("evening drink: chamomile tea before bed")
            )

            let transport = ScriptedTransport(steps: [
                .toolCall(name: "session_search", arguments: #"{"query":"drinks","limit":5}"#),
                .plainContent("""
                    ## Summary
                    The user prefers tea over coffee, by time of day.

                    ## Key Points
                    - Mornings: jasmine tea [[memory:abc]]
                    - Evenings: chamomile [[memory:def]]

                    ## Connections
                    Drinks correlate with energy intent.

                    ## Open Questions
                    Does this hold on weekends?
                    """)
            ])
            let service = Self.makeService(fluent: fluent, tmpRoot: tmpRoot, transport: transport)
            let result = try await service.generate(
                tenantID: tenantID,
                profileUsername: "memo-test",
                topic: "drinks",
                hint: nil,
                save: true
            )

            #expect(result.summary.contains("## Summary"))
            #expect(result.memo.hasPrefix("---\n"))           // frontmatter
            #expect(result.memo.contains("topic: \"drinks\""))
            #expect(result.memo.contains("## Key Points"))
            #expect(result.path != nil)
            #expect(result.path!.hasPrefix("memos/"))
            #expect(result.path!.hasSuffix("/drinks.md"))

            // Source memory IDs were collected from the search hit.
            #expect(result.sourceMemoryIDs.count >= 2)

            // On-disk + DB row both exist.
            let onDisk = tmpRoot
                .appendingPathComponent("vault")
                .appendingPathComponent("tenants")
                .appendingPathComponent(tenantID.uuidString)
                .appendingPathComponent("raw")
                .appendingPathComponent(result.path!)
            #expect(FileManager.default.fileExists(atPath: onDisk.path))

            let row = try await VaultFile
                .query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$path == result.path!)
                .first()
            #expect(row != nil)
            #expect(row?.contentType == "text/markdown")
        }
    }

    @Test
    func dryRunDoesNotPersist() async throws {
        try await Self.withFluent { fluent, tmpRoot in
            let tenantID = try await Self.makeTenant(on: fluent)
            let transport = ScriptedTransport(steps: [
                .plainContent("## Summary\nNothing here yet.")
            ])
            let service = Self.makeService(fluent: fluent, tmpRoot: tmpRoot, transport: transport)
            let result = try await service.generate(
                tenantID: tenantID,
                profileUsername: "memo-test",
                topic: "anything",
                hint: nil,
                save: false
            )
            #expect(result.path == nil)
            let rows = try await VaultFile.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(rows.isEmpty)
        }
    }

    @Test
    func loopMaxIterationsThrows() async throws {
        try await Self.withFluent { fluent, tmpRoot in
            let tenantID = try await Self.makeTenant(on: fluent)
            // Degenerate transport: always asks for another search, never plain content.
            let transport = ScriptedTransport(repeating: .toolCall(
                name: "session_search",
                arguments: #"{"query":"anything","limit":3}"#
            ))
            let service = Self.makeService(fluent: fluent, tmpRoot: tmpRoot, transport: transport)
            await #expect(throws: (any Error).self) {
                _ = try await service.generate(
                    tenantID: tenantID,
                    profileUsername: "memo-test",
                    topic: "loop",
                    hint: nil,
                    save: false
                )
            }
        }
    }

    @Test
    func slugSanitizesTopic() {
        #expect(MemoGeneratorService.slug("Hello World!") == "hello-world")
        #expect(MemoGeneratorService.slug("My drinks @ home") == "my-drinks-home")
        #expect(MemoGeneratorService.slug("---") == "memo")
        #expect(MemoGeneratorService.slug("") == "memo")
        #expect(MemoGeneratorService.slug(String(repeating: "x", count: 200)).count == 64)
    }
}

// MARK: - Scripted transport (same shape as HermesMemoryServiceTests')

private actor ScriptedTransport: HermesChatTransport {
    enum Step: Sendable {
        case toolCall(name: String, arguments: String)
        case plainContent(String)
    }

    private let steps: [Step]
    private let repeatingStep: Step?
    private var index: Int = 0

    init(steps: [Step]) { self.steps = steps; self.repeatingStep = nil }
    init(repeating: Step) { self.steps = []; self.repeatingStep = repeating }

    nonisolated func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await respond()
    }

    private func respond() throws -> Data {
        let step: Step
        if let repeating = repeatingStep {
            step = repeating
        } else if index < steps.count {
            step = steps[index]
            index += 1
        } else {
            throw NSError(domain: "scripted", code: -1)
        }
        return Self.encode(step: step)
    }

    private static func encode(step: Step) -> Data {
        switch step {
        case .toolCall(let name, let arguments):
            let json: [String: Any] = [
                "id": "test", "model": "test",
                "choices": [[
                    "index": 0, "finish_reason": "tool_calls",
                    "message": [
                        "role": "assistant", "content": NSNull(),
                        "tool_calls": [[
                            "id": "call_\(UUID().uuidString.prefix(8).lowercased())",
                            "type": "function",
                            "function": ["name": name, "arguments": arguments]
                        ]]
                    ]
                ]]
            ]
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        case .plainContent(let text):
            let json: [String: Any] = [
                "id": "test", "model": "test",
                "choices": [[
                    "index": 0, "finish_reason": "stop",
                    "message": ["role": "assistant", "content": text]
                ]]
            ]
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
    }
}
