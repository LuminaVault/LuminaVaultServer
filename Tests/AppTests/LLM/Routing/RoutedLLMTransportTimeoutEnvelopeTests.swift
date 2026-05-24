@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

@Suite(.serialized)
struct RoutedLLMTransportTimeoutEnvelopeTests {
    actor StubAdapter: ProviderAdapter {
        nonisolated let kind: ProviderKind
        private var error: ProviderError

        init(kind: ProviderKind, error: ProviderError) {
            self.kind = kind
            self.error = error
        }

        func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
            throw error
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
            fallbacks: [],
        )
        return RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test"),
        )
    }

    @Test
    func `exhausted timeout throws UpstreamErrorResponse with upstream_timeout`() async throws {
        let transport = Self.makeTransport(
            error: .network(provider: .hermesGateway, underlying: URLError(.timedOut)),
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                profileUsername: "alice",
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "upstream_timeout")
            #expect(err.status == .gatewayTimeout)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test
    func `exhausted unreachable throws UpstreamErrorResponse with upstream_unreachable`() async throws {
        let transport = Self.makeTransport(
            error: .network(provider: .hermesGateway, underlying: URLError(.cannotConnectToHost)),
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                profileUsername: "alice",
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
            error: .permanent(provider: .hermesGateway, status: 400, body: "bad json"),
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                profileUsername: "alice",
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
            fallbacks: [],
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test"),
        )
        do {
            _ = try await transport.chatCompletions(
                payload: Data(#"{"model":"hermes-3","messages":[]}"#.utf8),
                profileUsername: "alice",
            )
            Issue.record("expected throw")
        } catch let err as UpstreamErrorResponse {
            #expect(err.reasonCode == "no_providers")
            #expect(err.status == .badGateway)
        }
    }
}
