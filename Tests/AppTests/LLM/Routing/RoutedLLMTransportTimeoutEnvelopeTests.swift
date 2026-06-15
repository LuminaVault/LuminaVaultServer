@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct RoutedLLMTransportTimeoutEnvelopeTests {
    actor StubAdapter: ProviderAdapter {
        nonisolated let kind: ProviderKind
        private var error: ProviderError

        init(kind: ProviderKind, error: ProviderError) {
            self.kind = kind
            self.error = error
        }

        func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            throw error
        }
    }

    /// Throws non-ProviderError to exercise the unclassified-error path
    /// in RoutedLLMTransport (catches via the generic `catch` branch,
    /// sets `lastRecoverable` without `lastFailedCandidate`).
    actor UnclassifiedStubAdapter: ProviderAdapter {
        nonisolated let kind: ProviderKind
        private struct OpaqueError: Error {}

        init(kind: ProviderKind) {
            self.kind = kind
        }

        func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            throw OpaqueError()
        }
    }

    struct FixedRouter: ModelRouter {
        let decision: RouteDecision
        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            decision
        }
    }

    private static func makeTransport(error: ProviderError) -> RoutedLLMTransport {
        let adapter = StubAdapter(kind: .hermesGateway, error: error)
        let registry = ProviderRegistry(adapters: [adapter], logger: Logger(label: "test"))
        let decision = RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: "hermes-3"),
            fallbacks: []
        )
        return RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test")
        )
    }

    @Test
    func `exhausted timeout throws UpstreamErrorResponse with upstream_timeout`() async throws {
        let transport = Self.makeTransport(
            error: .network(provider: .hermesGateway, underlying: URLError(.timedOut))
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                sessionKey: "alice",
                sessionID: nil
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "upstream_timeout")
            #expect(err.status == .gatewayTimeout)
            #expect(err.retryAfterMs == 2000, "upstream_timeout envelope must include retry_after_ms hint")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test
    func `non-timeout exhaustion does NOT include retry_after_ms`() async throws {
        let transport = Self.makeTransport(
            error: .network(provider: .hermesGateway, underlying: URLError(.cannotConnectToHost))
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                sessionKey: "alice",
                sessionID: nil
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "upstream_unreachable")
            #expect(err.retryAfterMs == nil, "non-timeout codes carry no retry hint")
        }
    }

    @Test
    func `exhausted unreachable throws UpstreamErrorResponse with upstream_unreachable`() async throws {
        let transport = Self.makeTransport(
            error: .network(provider: .hermesGateway, underlying: URLError(.cannotConnectToHost))
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                sessionKey: "alice",
                sessionID: nil
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "upstream_unreachable")
            #expect(err.status == .badGateway)
        }
    }

    @Test
    func `permanent error throws UpstreamErrorResponse with upstream_rejected`() async throws {
        let transport = Self.makeTransport(
            error: .permanent(provider: .hermesGateway, status: 400, body: "bad json")
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                sessionKey: "alice",
                sessionID: nil
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "upstream_rejected")
            #expect(err.status == .badGateway)
        }
    }

    @Test
    func `no providers exhausted throws UpstreamErrorResponse with no_providers`() async throws {
        let registry = ProviderRegistry(adapters: [], logger: Logger(label: "test"))
        let decision = RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: "hermes-3"),
            fallbacks: []
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test")
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                sessionKey: "alice",
                sessionID: nil
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "no_providers")
            #expect(err.status == .badGateway)
        }
    }

    @Test
    func `exhausted unclassified errors throw UpstreamErrorResponse with upstream_error`() async throws {
        let adapter = UnclassifiedStubAdapter(kind: .hermesGateway)
        let registry = ProviderRegistry(adapters: [adapter], logger: Logger(label: "test"))
        let decision = RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: "hermes-3"),
            fallbacks: []
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test")
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                sessionKey: "alice",
                sessionID: nil
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "upstream_error")
            #expect(err.status == .badGateway)
        }
    }
}
