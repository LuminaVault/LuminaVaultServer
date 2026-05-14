@testable import App
import Foundation
import Logging
import Testing

/// HER-165/HER-161 — failover behaviour of `RoutedLLMTransport`.
/// No DB / no network. Stub adapters drive each scenario.
@Suite(.serialized)
struct RoutedLLMTransportTests {
    // MARK: - Stubs

    /// Records every chat call + plays back a programmable sequence of
    /// outcomes. Each call consumes one slot from `outcomes`; if the
    /// sequence is exhausted the test fails with a transient stub error.
    actor StubAdapter: ProviderAdapter {
        enum Outcome {
            case success(Data)
            case transient(status: Int)
            case permanent(status: Int)
            case network(NSError)
        }

        nonisolated let kind: ProviderKind
        var calls: [Data] = []
        private var outcomes: [Outcome]

        init(kind: ProviderKind, outcomes: [Outcome]) {
            self.kind = kind
            self.outcomes = outcomes
        }

        func chatCompletions(payload: Data, profileUsername _: String) async throws -> Data {
            calls.append(payload)
            guard !outcomes.isEmpty else {
                throw ProviderError.transient(provider: kind, status: 0, body: "stub: outcomes exhausted")
            }
            switch outcomes.removeFirst() {
            case let .success(data): return data
            case let .transient(status):
                throw ProviderError.transient(provider: kind, status: status, body: nil)
            case let .permanent(status):
                throw ProviderError.permanent(provider: kind, status: status, body: nil)
            case let .network(err):
                throw ProviderError.network(provider: kind, underlying: err)
            }
        }
    }

    /// Fixed-decision router so each test pins the candidate list it wants.
    struct FixedRouter: ModelRouter {
        let decision: RouteDecision
        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            decision
        }
    }

    private static func route(_ provider: ProviderKind, _ modelID: String = "stub") -> ModelRoute {
        ModelRoute(provider: provider, modelID: modelID)
    }

    private static func decision(primary: ProviderKind, fallbacks: [ProviderKind] = []) -> RouteDecision {
        RouteDecision(
            primary: route(primary),
            fallbacks: fallbacks.map { route($0) },
        )
    }

    private static func payload(model: String = "stub") -> Data {
        Data("{\"model\":\"\(model)\",\"messages\":[]}".utf8)
    }

    // MARK: - Tests

    @Test
    func `primary success returns data`() async throws {
        let primary = StubAdapter(kind: .hermesGateway, outcomes: [.success(Data("OK".utf8))])
        let registry = ProviderRegistry(adapters: [primary], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: Self.decision(primary: .hermesGateway)),
            logger: Logger(label: "test"),
        )
        let result = try await transport.chatCompletions(payload: Self.payload(), profileUsername: "alice")
        #expect(String(data: result, encoding: .utf8) == "OK")
        let calls = await primary.calls.count
        #expect(calls == 1)
    }

    @Test
    func `transient failovers to next`() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.transient(status: 429)])
        let fallback = StubAdapter(kind: .groq, outcomes: [.success(Data("FALLBACK".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: Self.decision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test"),
        )
        let result = try await transport.chatCompletions(payload: Self.payload(), profileUsername: "alice")
        #expect(String(data: result, encoding: .utf8) == "FALLBACK")
        let primaryCalls = await primary.calls.count
        let fallbackCalls = await fallback.calls.count
        #expect(primaryCalls == 1)
        #expect(fallbackCalls == 1)
    }

    @Test
    func `network error failovers to next`() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.network(NSError(domain: "test", code: -1))])
        let fallback = StubAdapter(kind: .groq, outcomes: [.success(Data("FALLBACK".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: Self.decision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test"),
        )
        _ = try await transport.chatCompletions(payload: Self.payload(), profileUsername: "alice")
        let primaryCalls = await primary.calls.count
        let fallbackCalls = await fallback.calls.count
        #expect(primaryCalls == 1)
        #expect(fallbackCalls == 1, "network errors must be treated as recoverable")
    }

    @Test
    func `permanent does not failover`() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.permanent(status: 400)])
        let fallback = StubAdapter(kind: .groq, outcomes: [.success(Data("WRONG".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: Self.decision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test"),
        )
        await #expect(throws: (any Error).self) {
            _ = try await transport.chatCompletions(payload: Self.payload(), profileUsername: "alice")
        }
        let fallbackCalls = await fallback.calls.count
        #expect(fallbackCalls == 0, "permanent failures must NOT touch the fallback — payload is bad")
    }

    @Test
    func `all candidates exhausted throws`() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.transient(status: 503)])
        let fallback = StubAdapter(kind: .groq, outcomes: [.transient(status: 502)])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: Self.decision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test"),
        )
        await #expect(throws: (any Error).self) {
            _ = try await transport.chatCompletions(payload: Self.payload(), profileUsername: "alice")
        }
        let primaryCalls = await primary.calls.count
        let fallbackCalls = await fallback.calls.count
        #expect(primaryCalls == 1)
        #expect(fallbackCalls == 1)
    }

    @Test
    func `unregistered provider is skipped`() async throws {
        let groq = StubAdapter(kind: .groq, outcomes: [.success(Data("OK".utf8))])
        let registry = ProviderRegistry(adapters: [groq], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: Self.decision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test"),
        )
        let result = try await transport.chatCompletions(payload: Self.payload(), profileUsername: "alice")
        #expect(String(data: result, encoding: .utf8) == "OK")
        let calls = await groq.calls.count
        #expect(calls == 1)
    }

    @Test
    func `routed model id is rewritten into the payload`() async throws {
        let primary = StubAdapter(kind: .hermesGateway, outcomes: [.success(Data("OK".utf8))])
        let registry = ProviderRegistry(adapters: [primary], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: RouteDecision(
                primary: ModelRoute(provider: .hermesGateway, modelID: "hermes-3-large"),
                fallbacks: [],
            )),
            logger: Logger(label: "test"),
        )
        _ = try await transport.chatCompletions(payload: Self.payload(model: "ignored"), profileUsername: "alice")

        let captured = await primary.calls.first
        let dict = try #require(captured.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(dict["model"] as? String == "hermes-3-large")
    }
}
