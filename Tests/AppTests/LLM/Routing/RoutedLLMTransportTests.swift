@testable import App
import Foundation
import Logging
import Testing

/// HER-165 — failover behaviour of `RoutedLLMTransport`.
/// No DB / no network. Stub adapters drive each scenario.
@Suite(.serialized)
struct RoutedLLMTransportTests {

    // MARK: - Stub adapter

    /// Records every chat call + plays back a programmable sequence of
    /// outcomes. Each call consumes one slot from `outcomes`; if the
    /// sequence is exhausted the test fails.
    actor StubAdapter: ProviderAdapter {
        enum Outcome: Sendable {
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
            case .success(let data): return data
            case .transient(let status):
                throw ProviderError.transient(provider: kind, status: status, body: nil)
            case .permanent(let status):
                throw ProviderError.permanent(provider: kind, status: status, body: nil)
            case .network(let err):
                throw ProviderError.network(provider: kind, underlying: err)
            }
        }
    }

    /// Fixed-decision router for the unit tests — bypasses the production
    /// `SingleGatewayModelRouter` so each test pins exactly the candidate
    /// list it wants.
    struct FixedRouter: ModelRouter {
        let decision: ModelDecision
        func pick(forModel _: String?, user _: User?) async -> ModelDecision { decision }
    }

    // MARK: - Tests

    @Test
    func primarySuccessReturnsData() async throws {
        let primary = StubAdapter(kind: .hermesGateway, outcomes: [.success(Data("OK".utf8))])
        let registry = ProviderRegistry(adapters: [primary], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: ModelDecision(primary: .hermesGateway, fallbacks: [])),
            logger: Logger(label: "test")
        )
        let result = try await transport.chatCompletions(payload: Data("body".utf8), profileUsername: "alice")
        #expect(String(data: result, encoding: .utf8) == "OK")
        let calls = await primary.calls.count
        #expect(calls == 1)
    }

    @Test
    func transientFailoversToNext() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.transient(status: 429)])
        let fallback = StubAdapter(kind: .groq, outcomes: [.success(Data("FALLBACK".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: ModelDecision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test")
        )
        let result = try await transport.chatCompletions(payload: Data("body".utf8), profileUsername: "alice")
        #expect(String(data: result, encoding: .utf8) == "FALLBACK")
        let primaryCalls = await primary.calls.count
        let fallbackCalls = await fallback.calls.count
        #expect(primaryCalls == 1)
        #expect(fallbackCalls == 1)
    }

    @Test
    func networkErrorFailoversToNext() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.network(NSError(domain: "test", code: -1))])
        let fallback = StubAdapter(kind: .groq, outcomes: [.success(Data("FALLBACK".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: ModelDecision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test")
        )
        _ = try await transport.chatCompletions(payload: Data("x".utf8), profileUsername: "alice")
        let primaryCalls = await primary.calls.count
        let fallbackCalls = await fallback.calls.count
        #expect(primaryCalls == 1)
        #expect(fallbackCalls == 1, "network errors must be treated as recoverable")
    }

    @Test
    func permanentDoesNotFailover() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.permanent(status: 400)])
        let fallback = StubAdapter(kind: .groq, outcomes: [.success(Data("WRONG".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: ModelDecision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test")
        )
        await #expect(throws: (any Error).self) {
            _ = try await transport.chatCompletions(payload: Data("x".utf8), profileUsername: "alice")
        }
        let fallbackCalls = await fallback.calls.count
        #expect(fallbackCalls == 0, "permanent failures must NOT touch the fallback — payload is bad")
    }

    @Test
    func allCandidatesExhaustedThrows() async throws {
        let primary = StubAdapter(kind: .together, outcomes: [.transient(status: 503)])
        let fallback = StubAdapter(kind: .groq, outcomes: [.transient(status: 502)])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: ModelDecision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test")
        )
        await #expect(throws: (any Error).self) {
            _ = try await transport.chatCompletions(payload: Data("x".utf8), profileUsername: "alice")
        }
        let primaryCalls = await primary.calls.count
        let fallbackCalls = await fallback.calls.count
        #expect(primaryCalls == 1)
        #expect(fallbackCalls == 1)
    }

    @Test
    func unregisteredProviderIsSkipped() async throws {
        // Decision references `together` (not registered) → skip → fall to `groq`.
        let groq = StubAdapter(kind: .groq, outcomes: [.success(Data("OK".utf8))])
        let registry = ProviderRegistry(adapters: [groq], logger: Logger(label: "test"))
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: ModelDecision(primary: .together, fallbacks: [.groq])),
            logger: Logger(label: "test")
        )
        let result = try await transport.chatCompletions(payload: Data("x".utf8), profileUsername: "alice")
        #expect(String(data: result, encoding: .utf8) == "OK")
        let calls = await groq.calls.count
        #expect(calls == 1)
    }
}
