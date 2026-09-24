@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// OpenRouter retires a `:free` tier by answering 404 "This model is
/// unavailable for free". The payload is fine and the next rung can still serve
/// the turn, so on the free lane a 404 must advance instead of ending the chain —
/// and whatever finally reaches the client must not name the provider or slug.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct FreeLaneModelUnavailableFailoverTests {
    actor QueueAdapter: ProviderAdapter {
        enum Outcome {
            case reply(String)
            case fail(ProviderError)
        }

        nonisolated let kind: ProviderKind
        private var outcomes: [Outcome]
        private(set) var models: [String] = []

        init(kind: ProviderKind, outcomes: [Outcome]) {
            self.kind = kind
            self.outcomes = outcomes
        }

        func chatCompletions(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            models.append(object?["model"] as? String ?? "")
            guard !outcomes.isEmpty else {
                throw ProviderError.transient(provider: kind, status: 0, body: "stub exhausted")
            }
            switch outcomes.removeFirst() {
            case let .reply(text):
                return Data(#"{"choices":[{"message":{"role":"assistant","content":"\#(text)"}}]}"#.utf8)
            case let .fail(error):
                throw error
            }
        }
    }

    struct FixedRouter: ModelRouter {
        let decision: RouteDecision
        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            decision
        }
    }

    private static let unavailableForFree = Data(
        #"{"error":{"message":"nvidia/nemotron-3-ultra-550b-a55b:free: This model is unavailable for free","code":404}}"#.utf8
    )

    private static func notFound(_ provider: ProviderKind) -> ProviderError {
        ProviderErrorClassifier.classify(provider: provider, status: 404, body: unavailableForFree)
    }

    private static func decision(freeLane: Bool) -> RouteDecision {
        let routes = FreeLaneCatalog.routes().compactMap { route in
            ProviderKind(shared: route.provider).map { ModelRoute(provider: $0, modelID: route.model) }
        }
        let tenantID = UUID()
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
            routes: [],
            synthesisRoute: nil,
            minimumSuccessfulResults: 1,
            retryPolicy: .fast,
            predictedCostUsdMicros: 0,
            budgetReservationUsdMicros: 0,
            budgetDenied: false,
            mode: .managed,
            routingPolicy: .locked,
            isFreeLane: freeLane
        )
        return RouteDecision(
            primary: routes[0],
            fallbacks: Array(routes.dropFirst()),
            cerberus: metadata
        )
    }

    private static func stream(
        _ decision: RouteDecision,
        adapters: [any ProviderAdapter]
    ) async throws -> String {
        let transport = RoutedLLMTransport(
            registry: ProviderRegistry(adapters: adapters, logger: Logger(label: "test.freelane.404")),
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test.freelane.404")
        )
        var text = ""
        for try await chunk in transport.chatStream(
            payload: Data(#"{"model":"lumina","messages":[{"role":"user","content":"hi"}]}"#.utf8),
            sessionKey: "alice",
            sessionID: nil,
            decision: decision
        ) {
            text += chunk.delta
        }
        return text
    }

    @Test
    func `the classifier still reads a 404 as permanent`() {
        let error = Self.notFound(.openRouter)
        #expect(!error.isRecoverable)
        #expect(!RoutedLLMTransport.shouldAdvance(after: error, freeLane: false))
        #expect(RoutedLLMTransport.shouldAdvance(after: error, freeLane: true))
    }

    @Test
    func `other permanent errors stop the free lane`() {
        let badRequest = ProviderError.permanent(provider: .openRouter, status: 400, body: nil)
        let unauthorized = ProviderError.permanent(provider: .openRouter, status: 401, body: nil)
        #expect(!RoutedLLMTransport.shouldAdvance(after: badRequest, freeLane: true))
        #expect(!RoutedLLMTransport.shouldAdvance(after: unauthorized, freeLane: true))
    }

    @Test
    func `a retired primary free slug falls through to the secondary`() async throws {
        let openRouter = QueueAdapter(kind: .openRouter, outcomes: [.fail(Self.notFound(.openRouter)), .reply("from super")])
        let nvidia = QueueAdapter(kind: .nvidia, outcomes: [.reply("from nim")])

        let text = try await Self.stream(Self.decision(freeLane: true), adapters: [openRouter, nvidia])

        #expect(text == "from super")
        #expect(await openRouter.models == [
            FreeLaneCatalog.defaultOpenRouterModel,
            FreeLaneCatalog.defaultOpenRouterSecondaryModel,
        ])
        #expect(await nvidia.models.isEmpty)
    }

    @Test
    func `both free slugs retired falls through to the NIM reserve`() async throws {
        let openRouter = QueueAdapter(
            kind: .openRouter,
            outcomes: [.fail(Self.notFound(.openRouter)), .fail(Self.notFound(.openRouter))]
        )
        let nvidia = QueueAdapter(kind: .nvidia, outcomes: [.reply("from nim")])

        let text = try await Self.stream(Self.decision(freeLane: true), adapters: [openRouter, nvidia])

        #expect(text == "from nim")
        #expect(await nvidia.models == [FreeLaneCatalog.defaultNvidiaModel])
    }

    @Test
    func `outside the free lane a 404 still ends the chain`() async throws {
        let openRouter = QueueAdapter(kind: .openRouter, outcomes: [.fail(Self.notFound(.openRouter)), .reply("from super")])
        let nvidia = QueueAdapter(kind: .nvidia, outcomes: [.reply("from nim")])

        await #expect(throws: UpstreamErrorResponse.self) {
            _ = try await Self.stream(Self.decision(freeLane: false), adapters: [openRouter, nvidia])
        }
        #expect(await openRouter.models.count == 1)
    }

    /// Free-lane turns run as managed; the terminal error must not name the
    /// provider or echo the upstream body, which carries the slug.
    @Test
    func `a fully failed free lane names no provider or model`() async throws {
        let openRouter = QueueAdapter(
            kind: .openRouter,
            outcomes: [.fail(Self.notFound(.openRouter)), .fail(Self.notFound(.openRouter))]
        )
        let nvidia = QueueAdapter(kind: .nvidia, outcomes: [.fail(Self.notFound(.nvidia))])

        do {
            _ = try await Self.stream(Self.decision(freeLane: true), adapters: [openRouter, nvidia])
            Issue.record("expected the exhausted lane to throw")
        } catch let error as UpstreamErrorResponse {
            #expect(error.userMessage == RoutedLLMTransport.freeLaneFailureMessage)
            let lower = error.userMessage.lowercased()
            for leak in ["openrouter", "nvidia", "nemotron", ":free"] {
                #expect(!lower.contains(leak), "free-lane error leaks \(leak)")
            }
        }
    }
}
