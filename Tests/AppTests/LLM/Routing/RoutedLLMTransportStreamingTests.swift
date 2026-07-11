@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct RoutedLLMTransportStreamingTests {
    actor StreamingStubAdapter: StreamingProviderAdapter {
        nonisolated let kind: ProviderKind = .openai
        private(set) var calls: [Data] = []

        func chatCompletions(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            calls.append(payload)
            return Self.openAIResponse("fallback full reply")
        }

        func chatCompletionsStream(
            payload: Data,
            sessionKey _: String,
            sessionID _: String?
        ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
            calls.append(payload)
            return AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamChunk(delta: "Hel"))
                continuation.yield(ChatStreamChunk(delta: "lo", finishReason: "stop"))
                continuation.finish()
            }
        }

        private static func openAIResponse(_ content: String) -> Data {
            Data(#"{"choices":[{"message":{"role":"assistant","content":"\#(content)"}}]}"#.utf8)
        }
    }

    actor NonStreamingStubAdapter: ProviderAdapter {
        nonisolated let kind: ProviderKind = .openai
        private(set) var calls: [Data] = []

        func chatCompletions(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            calls.append(payload)
            return Data(#"{"choices":[{"message":{"role":"assistant","content":"complete answer"}}]}"#.utf8)
        }
    }

    struct FixedRouter: ModelRouter {
        func pick(forModel model: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            RouteDecision(
                primary: ModelRoute(provider: .openai, modelID: model ?? "gpt-test"),
                fallbacks: []
            )
        }
    }

    struct FailingManagedFallback: HermesLLMStreamService {
        func chatStream(
            sessionKey _: String,
            sessionID _: String?,
            request _: ChatRequest
        ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: HTTPError(.internalServerError, message: "managed fallback should not be used"))
            }
        }
    }

    private static func withBYOKHarness<T: Sendable>(
        _ body: @Sendable (User, UserLLMPreferenceRepository) async throws -> T
    ) async throws -> T {
        try await withTestFluent(label: "test.routed-streaming") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = UUID()
            let user = User(
                id: tenantID,
                email: "stream-\(tenantID.uuidString.prefix(8).lowercased())@test.luminavault",
                username: "stream-\(tenantID.uuidString.prefix(8).lowercased())",
                passwordHash: "x"
            )
            try await user.save(on: fluent.db())
            let preferences = UserLLMPreferenceRepository(
                fluent: fluent,
                logger: Logger(label: "test.routed-streaming")
            )
            _ = try await preferences.upsert(
                tenantID: tenantID,
                mode: .byok,
                primaryProvider: .openai,
                primaryModel: "gpt-stream",
                fallbackChain: [],
                allowedProviders: [],
                blockedProviders: []
            )
            return try await body(user, preferences)
        }
    }

    private static func collect(
        _ stream: AsyncThrowingStream<ChatStreamChunk, Error>
    ) async throws -> [ChatStreamChunk] {
        var chunks: [ChatStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private static func makeService(
        adapter: any ProviderAdapter,
        user: User,
        preferences: UserLLMPreferenceRepository
    ) -> RoutedHermesLLMStreamService {
        let registry = ProviderRegistry(adapters: [adapter], logger: Logger(label: "test.routed-streaming"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(),
            currentUser: { user },
            logger: Logger(label: "test.routed-streaming")
        )
        return RoutedHermesLLMStreamService(
            fallback: FailingManagedFallback(),
            transport: transport,
            preferences: preferences,
            logger: Logger(label: "test.routed-streaming")
        )
    }

    @Test
    func `BYOK uses native provider streaming when selected adapter supports it`() async throws {
        try await Self.withBYOKHarness { user, preferences in
            let adapter = StreamingStubAdapter()
            let service = Self.makeService(adapter: adapter, user: user, preferences: preferences)
            let chunks = try await Self.collect(service.chatStream(
                sessionKey: user.requireID().uuidString,
                sessionID: "conversation-1",
                request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
            ))

            #expect(chunks == [
                ChatStreamChunk(delta: "Hel"),
                ChatStreamChunk(delta: "lo", finishReason: "stop"),
            ])
            let captured = try #require(await adapter.calls.first)
            let payload = try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
            #expect(payload["model"] as? String == "gpt-stream")
            #expect(payload["stream"] as? Bool == true)
        }
    }

    @Test
    func `BYOK keeps one chunk fallback when selected adapter does not support streaming`() async throws {
        try await Self.withBYOKHarness { user, preferences in
            let adapter = NonStreamingStubAdapter()
            let service = Self.makeService(adapter: adapter, user: user, preferences: preferences)
            let chunks = try await Self.collect(service.chatStream(
                sessionKey: user.requireID().uuidString,
                sessionID: "conversation-1",
                request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
            ))

            #expect(chunks == [ChatStreamChunk(delta: "complete answer", finishReason: "stop")])
            let captured = try #require(await adapter.calls.first)
            let payload = try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
            #expect(payload["model"] as? String == "gpt-stream")
            #expect(payload["stream"] == nil)
        }
    }
}
