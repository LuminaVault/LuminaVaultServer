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
    /// Streams the way every production chat adapter does now: by
    /// implementing `ProviderAdapter.chatStream` itself. It used to implement
    /// `StreamingProviderAdapter.chatCompletionsStream`, the hook native
    /// streaming ran through in July; that path was folded into each adapter's
    /// `chatStream`, and nothing calls `chatCompletionsStream` any more. A stub
    /// still speaking the old hook inherited `ProviderAdapter`'s buffering
    /// default, which is why this test saw one "fallback full reply" chunk.
    actor StreamingStubAdapter: ProviderAdapter {
        nonisolated let kind: ProviderKind = .openai
        private(set) var calls: [Data] = []

        func chatCompletions(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            calls.append(payload)
            return Self.openAIResponse("fallback full reply")
        }

        nonisolated func chatStream(
            payload: Data,
            sessionKey _: String,
            sessionID _: String?
        ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.record(payload)
                    continuation.yield(ChatStreamChunk(delta: "Hel"))
                    continuation.yield(ChatStreamChunk(delta: "lo", finishReason: "stop"))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func record(_ payload: Data) {
            calls.append(payload)
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

    struct FixedDecisionRouter: ModelRouter {
        let decision: RouteDecision

        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            decision
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
            // M90: tenant_id references vaults(id). Registration provisions the
            // vault; a test saving a User directly must do the same.
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
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

    private static func withManagedHarness<T: Sendable>(
        _ body: @Sendable (User, UserLLMPreferenceRepository) async throws -> T
    ) async throws -> T {
        try await withTestFluent(label: "test.routed-streaming-managed") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = UUID()
            let user = User(
                id: tenantID,
                email: "stream-managed-\(tenantID.uuidString.prefix(8).lowercased())@test.luminavault",
                username: "stream-managed-\(tenantID.uuidString.prefix(8).lowercased())",
                passwordHash: "x"
            )
            try await user.save(on: fluent.db())
            // M90: tenant_id references vaults(id). Registration provisions the
            // vault; a test saving a User directly must do the same.
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
            let preferences = UserLLMPreferenceRepository(
                fluent: fluent,
                logger: Logger(label: "test.routed-streaming-managed")
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

    private static func managedBudgetDeniedDecision(tenantID: UUID) -> RouteDecision {
        let route = RouterModelRouteDTO(provider: .openRouter, model: "openrouter/auto")
        let metadata = CerberusDecisionMetadata(
            executionID: UUID(),
            tenantID: tenantID,
            vaultID: tenantID,
            actorUserID: tenantID,
            profileID: UUID(),
            profileName: "Managed Auto",
            ruleID: nil,
            taskType: .general,
            surface: .chat,
            spaceID: nil,
            conversationID: nil,
            strategy: .sequential,
            parallelStrategy: nil,
            participants: nil,
            routes: [route],
            synthesisRoute: nil,
            minimumSuccessfulResults: 1,
            retryPolicy: .fast,
            predictedCostUsdMicros: 100,
            budgetReservationUsdMicros: 0,
            budgetDenied: true,
            mode: .managed,
            routingPolicy: .autoSmart,
            complexity: .medium,
            reason: "hard budget exceeded"
        )
        return RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: route.model),
            fallbacks: [],
            cerberus: metadata
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
            // `stream: true` is not the transport's to set any more: each
            // adapter adds it to its own upstream request inside `chatStream`
            // (`ProviderStreamKit.withStreamFlag`, pinned in
            // `ProviderStreamKitStreamFlagTests`). The proof that the native
            // stream was used here is the two chunks above, not a flag.
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

    @Test
    func `managed Auto streaming fails closed when router budget is denied`() async throws {
        try await Self.withManagedHarness { user, preferences in
            let tenantID = try user.requireID()
            let transport = RoutedLLMTransport(
                registry: ProviderRegistry(adapters: [], logger: Logger(label: "test.routed-streaming-managed")),
                router: FixedDecisionRouter(decision: Self.managedBudgetDeniedDecision(tenantID: tenantID)),
                currentUser: { user },
                logger: Logger(label: "test.routed-streaming-managed")
            )
            let service = RoutedHermesLLMStreamService(
                fallback: FailingManagedFallback(),
                transport: transport,
                preferences: preferences,
                logger: Logger(label: "test.routed-streaming-managed"),
                router: FixedDecisionRouter(decision: Self.managedBudgetDeniedDecision(tenantID: tenantID))
            )

            await #expect(throws: UsageCapExceededError.self) {
                _ = try await Self.collect(service.chatStream(
                    sessionKey: tenantID.uuidString,
                    sessionID: "conversation-1",
                    request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
                ))
            }
        }
    }

    @Test
    func `BYOK stream pins the preference model when Cerberus advertised Hermes`() async throws {
        try await Self.withBYOKHarness { user, preferences in
            let adapter = StreamingStubAdapter()
            let tenantID = try user.requireID()
            let advertised = RouterModelRouteDTO(provider: .openRouter, model: "hermes-3")
            let transport = RoutedLLMTransport(
                registry: ProviderRegistry(adapters: [adapter], logger: Logger(label: "test.routed-streaming")),
                router: FixedDecisionRouter(decision: RouteDecision(
                    primary: ModelRoute(provider: .hermesGateway, modelID: "hermes-3"),
                    fallbacks: [],
                    cerberus: CerberusDecisionMetadata(
                        executionID: UUID(),
                        tenantID: tenantID,
                        vaultID: tenantID,
                        actorUserID: tenantID,
                        profileID: UUID(),
                        profileName: "BYO Hermes",
                        ruleID: nil,
                        taskType: .general,
                        surface: .chat,
                        spaceID: nil,
                        conversationID: nil,
                        strategy: .sequential,
                        parallelStrategy: nil,
                        participants: nil,
                        routes: [advertised],
                        synthesisRoute: nil,
                        minimumSuccessfulResults: 1,
                        retryPolicy: .fast,
                        predictedCostUsdMicros: 0,
                        budgetReservationUsdMicros: 0,
                        budgetDenied: false,
                        mode: .byok,
                        routingPolicy: .locked,
                        deferredToHermes: true
                    ),
                    credentialMode: .byok
                )),
                currentUser: { user },
                logger: Logger(label: "test.routed-streaming")
            )
            let service = RoutedHermesLLMStreamService(
                fallback: FailingManagedFallback(),
                transport: transport,
                preferences: preferences,
                logger: Logger(label: "test.routed-streaming")
            )
            let events = RoutingCapture()
            let chunks = try await LLMRoutingContext.withValues({
                $0.cerberusSink = { events.append($0) }
                $0.currentUser = user
            }) {
                try await Self.collect(service.chatStream(
                    sessionKey: tenantID.uuidString,
                    sessionID: "conversation-1",
                    request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
                ))
            }

            #expect(!chunks.isEmpty)
            #expect(chunks.contains { !$0.delta.isEmpty })
            let routing = try #require(events.routing.first)
            #expect(routing.activeRoutes == [RouterModelRouteDTO(provider: .openai, model: "gpt-stream")])
            #expect(routing.profileName == "BYO Hermes")
            let captured = try #require(await adapter.calls.first)
            let payload = try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
            #expect(payload["model"] as? String == "gpt-stream")
        }
    }

    // MARK: - Free lane

    /// A provider stub of any kind that streams two chunks and records every
    /// payload it was sent, so a test can prove who was — and was not — called.
    actor LaneStubAdapter: ProviderAdapter {
        nonisolated let kind: ProviderKind
        private(set) var calls: [Data] = []

        init(kind: ProviderKind) {
            self.kind = kind
        }

        func chatCompletions(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            calls.append(payload)
            return Data(#"{"choices":[{"message":{"role":"assistant","content":"lane reply"}}]}"#.utf8)
        }

        nonisolated func chatStream(
            payload: Data,
            sessionKey _: String,
            sessionID _: String?
        ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.record(payload)
                    continuation.yield(ChatStreamChunk(delta: "free "))
                    continuation.yield(ChatStreamChunk(delta: "reply", finishReason: "stop"))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func record(_ payload: Data) {
            calls.append(payload)
        }
    }

    /// What `CerberusRouterService.freeLaneDecision` returns: managed, locked,
    /// flagged as the lane, routed to one free OpenRouter model.
    private static func freeLaneDecision(tenantID: UUID, exhausted: Bool = false) -> RouteDecision {
        let route = RouterModelRouteDTO(provider: .openRouter, model: "free/lane-model:free")
        let metadata = CerberusDecisionMetadata(
            executionID: UUID(),
            tenantID: tenantID,
            vaultID: tenantID,
            actorUserID: tenantID,
            profileID: UUID(),
            profileName: "Free lane",
            ruleID: nil,
            taskType: .general,
            surface: .chat,
            spaceID: nil,
            conversationID: nil,
            strategy: .sequential,
            parallelStrategy: nil,
            participants: nil,
            routes: exhausted ? [] : [route],
            synthesisRoute: nil,
            minimumSuccessfulResults: 1,
            retryPolicy: .fast,
            predictedCostUsdMicros: 0,
            budgetReservationUsdMicros: 0,
            budgetDenied: false,
            mode: .managed,
            routingPolicy: .locked,
            complexity: .medium,
            reason: exhausted ? "Free lane exhausted" : "Free lane: openRouterFree",
            isFreeLane: true,
            freeLaneExhausted: exhausted,
            freeLaneRetryAfterSeconds: exhausted ? 3600 : 0
        )
        return RouteDecision(
            primary: ModelRoute(provider: .openRouter, modelID: route.model),
            fallbacks: [],
            cerberus: metadata,
            credentialMode: .managed
        )
    }

    /// The cost bug. A free-lane decision is `locked`, and the managed stream
    /// branch only honoured `autoSmart` decisions, so it fell through to the
    /// managed gateway — the platform's paid key — having already charged the
    /// lane for the message. `FailingManagedFallback` is that gateway: reaching
    /// it fails the test.
    @Test
    func `a granted free lane streams through the routed transport, never the paid gateway`() async throws {
        try await Self.withManagedHarness { user, preferences in
            let tenantID = try user.requireID()
            let lane = LaneStubAdapter(kind: .openRouter)
            let decision = Self.freeLaneDecision(tenantID: tenantID)
            let transport = RoutedLLMTransport(
                registry: ProviderRegistry(adapters: [lane], logger: Logger(label: "test.free-lane-stream")),
                router: FixedDecisionRouter(decision: decision),
                currentUser: { user },
                logger: Logger(label: "test.free-lane-stream")
            )
            let service = RoutedHermesLLMStreamService(
                fallback: FailingManagedFallback(),
                transport: transport,
                preferences: preferences,
                logger: Logger(label: "test.free-lane-stream"),
                router: FixedDecisionRouter(decision: decision)
            )

            let chunks = try await Self.collect(service.chatStream(
                sessionKey: tenantID.uuidString,
                sessionID: "conversation-1",
                request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
            ))

            #expect(chunks.map(\.delta).joined() == "free reply")
            #expect(await lane.calls.count == 1)
        }
    }

    /// And when the lane is spent, the stream must stop — not carry on for
    /// free on the paid gateway.
    @Test
    func `an exhausted free lane ends the stream instead of falling back to the gateway`() async throws {
        try await Self.withManagedHarness { user, preferences in
            let tenantID = try user.requireID()
            let decision = Self.freeLaneDecision(tenantID: tenantID, exhausted: true)
            let transport = RoutedLLMTransport(
                registry: ProviderRegistry(adapters: [], logger: Logger(label: "test.free-lane-stream")),
                router: FixedDecisionRouter(decision: decision),
                currentUser: { user },
                logger: Logger(label: "test.free-lane-stream")
            )
            let service = RoutedHermesLLMStreamService(
                fallback: FailingManagedFallback(),
                transport: transport,
                preferences: preferences,
                logger: Logger(label: "test.free-lane-stream"),
                router: FixedDecisionRouter(decision: decision)
            )

            await #expect(throws: FreeLaneExhaustedError.self) {
                _ = try await Self.collect(service.chatStream(
                    sessionKey: tenantID.uuidString,
                    sessionID: "conversation-1",
                    request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
                ))
            }
        }
    }

    /// The second cost bug. A BYOK tenant with no key is diverted to the free
    /// lane, but the BYOK branch pins their stored model as a forced route, and
    /// `applyingForcedRoute` swapped it in while keeping the managed credential
    /// mode. The platform key then paid for whatever model they had pinned.
    @Test
    func `a forced route never overrides a free-lane decision`() {
        let decision = Self.freeLaneDecision(tenantID: UUID())
        let applied = LLMRoutingContext.withValues({
            $0.forcedRoute = RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-7")
        }) {
            RoutedLLMTransport.applyingForcedRoute(decision)
        }
        #expect(applied.primary.provider == .openRouter)
        #expect(applied.primary.modelID == "free/lane-model:free")
    }

    @Test
    func `a BYOK tenant without keys is served by the lane, never their pinned model`() async throws {
        try await Self.withBYOKHarness { user, preferences in
            let tenantID = try user.requireID()
            // The harness pins openai/gpt-stream as the BYOK preference.
            let pinned = LaneStubAdapter(kind: .openai)
            let lane = LaneStubAdapter(kind: .openRouter)
            let decision = Self.freeLaneDecision(tenantID: tenantID)
            let transport = RoutedLLMTransport(
                registry: ProviderRegistry(adapters: [pinned, lane], logger: Logger(label: "test.free-lane-byok")),
                router: FixedDecisionRouter(decision: decision),
                currentUser: { user },
                logger: Logger(label: "test.free-lane-byok")
            )
            let service = RoutedHermesLLMStreamService(
                fallback: FailingManagedFallback(),
                transport: transport,
                preferences: preferences,
                logger: Logger(label: "test.free-lane-byok"),
                router: FixedDecisionRouter(decision: decision)
            )

            _ = try await Self.collect(service.chatStream(
                sessionKey: tenantID.uuidString,
                sessionID: "conversation-1",
                request: ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)
            ))

            #expect(await pinned.calls.isEmpty, "the pinned model was dispatched on the platform key")
            #expect(await lane.calls.count == 1)
        }
    }
}

private final class RoutingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [QueryStreamEvent] = []

    var routing: [RouterRoutingEventDTO] {
        lock.withLock {
            events.compactMap { event in
                guard case let .routing(routing) = event else { return nil }
                return routing
            }
        }
    }

    func append(_ event: QueryStreamEvent) {
        lock.withLock { events.append(event) }
    }
}
