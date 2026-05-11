import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import App

/// Drives the HermesMemoryService agent loop against a stub transport so
/// tool-call dispatch + DB writes are exercised without a live Hermes.
/// Postgres MUST be up: `docker compose up -d postgres`.
@Suite(.serialized)
struct HermesMemoryServiceTests {

    // MARK: - Fixtures

    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T
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
        let fluent = Fluent(logger: Logger(label: "test.memory"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
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
        await fluent.migrations.add(M15_AddTierFields())
        try await fluent.migrate()
        return fluent
    }

    private static func createTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "mem-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault",
            username: "mem-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        return id
    }

    // MARK: - Tests

    @Test
    func upsertDispatchesMemoryUpsertAndPersists() async throws {
        try await Self.withFluent { fluent in
            let tenantID = try await Self.createTenant(on: fluent)
            let transport = ScriptedTransport(steps: [
                // Turn 1: model decides to call memory_upsert
                .toolCall(
                    name: "memory_upsert",
                    arguments: #"{"content":"alice prefers tea over coffee"}"#
                ),
                // Turn 2: after tool returns, plain acknowledgement
                .plainContent("Saved that you prefer tea over coffee.")
            ])
            let service = HermesMemoryService(
                transport: transport,
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test",
                logger: Logger(label: "test.memory")
            )

            let result = try await service.upsert(
                tenantID: tenantID,
                profileUsername: "alice",
                content: "I prefer tea over coffee."
            )

            #expect(result.summary == "Saved that you prefer tea over coffee.")
            #expect(result.memory.content == "alice prefers tea over coffee")

            // Persisted under the right tenant
            let rows = try await Memory.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(rows.count == 1)
            #expect(rows[0].content == "alice prefers tea over coffee")

            // Verify the transport saw the X-Hermes-Profile header pinned to alice
            let calls = await transport.calls
            #expect(calls.count == 2)
            #expect(calls.allSatisfy { $0.profileUsername == "alice" })
        }
    }

    @Test
    func searchDispatchesSessionSearchAndReturnsHits() async throws {
        try await Self.withFluent { fluent in
            let tenantID = try await Self.createTenant(on: fluent)
            let repo = MemoryRepository(fluent: fluent)
            let embedder = DeterministicEmbeddingService()
            // Seed two memories so search has something to find.
            _ = try await repo.create(
                tenantID: tenantID,
                content: "favourite drink: jasmine tea",
                embedding: try await embedder.embed("favourite drink: jasmine tea")
            )
            _ = try await repo.create(
                tenantID: tenantID,
                content: "weekly sleep average: 7.2 hours",
                embedding: try await embedder.embed("weekly sleep average: 7.2 hours")
            )

            let transport = ScriptedTransport(steps: [
                .toolCall(
                    name: "session_search",
                    arguments: #"{"query":"what does the user drink","limit":3}"#
                ),
                .plainContent("Your notes mention jasmine tea as the favourite drink.")
            ])
            let service = HermesMemoryService(
                transport: transport,
                memories: repo,
                embeddings: embedder,
                defaultModel: "test",
                logger: Logger(label: "test.memory")
            )

            let answer = try await service.search(
                tenantID: tenantID,
                profileUsername: "alice",
                query: "what does the user drink"
            )

            #expect(answer.summary.contains("jasmine"))
            #expect(answer.hits.count == 2) // both rows return; ANN order depends on embedding
            #expect(answer.hits.contains { $0.content.contains("jasmine") })
        }
    }

    @Test
    func plainAssistantContentSkipsToolDispatch() async throws {
        try await Self.withFluent { fluent in
            let tenantID = try await Self.createTenant(on: fluent)
            let transport = ScriptedTransport(steps: [
                .plainContent("Got it.") // no tool calls
            ])
            let service = HermesMemoryService(
                transport: transport,
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test",
                logger: Logger(label: "test.memory")
            )
            await #expect(throws: (any Error).self) {
                _ = try await service.upsert(
                    tenantID: tenantID,
                    profileUsername: "bob",
                    content: "remember anything"
                )
            }
            // No memory persisted because handler never ran.
            let rows = try await Memory.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(rows.isEmpty)
        }
    }

    @Test
    func agentLoopRespectsMaxIterations() async throws {
        try await Self.withFluent { fluent in
            let tenantID = try await Self.createTenant(on: fluent)
            // Transport that ALWAYS asks for another memory_upsert (degenerate model).
            let transport = ScriptedTransport(repeating: .toolCall(
                name: "memory_upsert",
                arguments: #"{"content":"stuck in a loop"}"#
            ))
            let service = HermesMemoryService(
                transport: transport,
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test",
                logger: Logger(label: "test.memory"),
                maxToolIterations: 3
            )
            await #expect(throws: (any Error).self) {
                _ = try await service.upsert(
                    tenantID: tenantID,
                    profileUsername: "carol",
                    content: "loop me"
                )
            }
        }
    }
}

// MARK: - Test transport

/// Plays back a fixed script of canned chat-completion responses so the
/// agent loop can be exercised without a live Hermes container.
private actor ScriptedTransport: HermesChatTransport {

    enum Step: Sendable {
        case toolCall(name: String, arguments: String)
        case plainContent(String)
    }

    struct Call: Sendable {
        let profileUsername: String
        let payload: Data
    }

    private let steps: [Step]
    private let repeatingStep: Step?
    private(set) var calls: [Call] = []
    private var index: Int = 0

    init(steps: [Step]) {
        self.steps = steps
        self.repeatingStep = nil
    }

    init(repeating: Step) {
        self.steps = []
        self.repeatingStep = repeating
    }

    nonisolated func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await record(payload: payload, profileUsername: profileUsername)
    }

    private func record(payload: Data, profileUsername: String) throws -> Data {
        calls.append(Call(profileUsername: profileUsername, payload: payload))
        let step: Step
        if let repeating = repeatingStep {
            step = repeating
        } else if index < steps.count {
            step = steps[index]
            index += 1
        } else {
            throw ScriptedTransportError.scriptExhausted
        }
        return Self.encode(step: step)
    }

    private static func encode(step: Step) -> Data {
        switch step {
        case .toolCall(let name, let arguments):
            let json: [String: Any] = [
                "id": "test-resp",
                "model": "test",
                "choices": [
                    [
                        "index": 0,
                        "finish_reason": "tool_calls",
                        "message": [
                            "role": "assistant",
                            "content": NSNull(),
                            "tool_calls": [
                                [
                                    "id": "call_\(UUID().uuidString.prefix(8).lowercased())",
                                    "type": "function",
                                    "function": [
                                        "name": name,
                                        "arguments": arguments
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        case .plainContent(let text):
            let json: [String: Any] = [
                "id": "test-resp",
                "model": "test",
                "choices": [
                    [
                        "index": 0,
                        "finish_reason": "stop",
                        "message": [
                            "role": "assistant",
                            "content": text
                        ]
                    ]
                ]
            ]
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
    }
}

private enum ScriptedTransportError: Error { case scriptExhausted }
