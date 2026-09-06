@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Where a BYO tenant's chat actually goes.
///
/// `CerberusModelRouter.pick` has always claimed to defer to the user's box —
/// `profileName: "BYO Hermes"`, `deferredToHermes: true` — while returning
/// `table.primary`. `TableModelRouter` appends the gateway route *last*, so
/// with platform keys configured (they are, in production) the primary was
/// Anthropic on the platform's key and the user's own Hermes was candidate #4.
///
/// The fallbacks mattered just as much: `RoutedLLMTransport` retries down
/// `candidates` on any recoverable network error, so a blip on the user's
/// tailnet quietly sent their prompt to a platform provider — traffic they
/// had deliberately kept on their own hardware.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct BYOHermesRoutingTests {
    /// The production shape: platform providers ranked first, the gateway
    /// appended last, exactly as `TableModelRouter` builds it.
    private struct PlatformFirstTableRouter: ModelRouter {
        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            RouteDecision(
                primary: ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4-6"),
                fallbacks: [
                    ModelRoute(provider: .openai, modelID: "gpt-5"),
                    ModelRoute(provider: .hermesGateway, modelID: "hermes-3"),
                ]
            )
        }
    }

    private static func user() -> User {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return User(
            id: UUID(),
            email: "byo-route-\(suffix)@test.luminavault",
            username: "byo-route-\(suffix)",
            passwordHash: "",
            tier: UserTier.pro.rawValue
        )
    }

    private static func router(fluent: Fluent) -> CerberusModelRouter {
        let logger = Logger(label: "test.byo.routing")
        return CerberusModelRouter(
            profiles: RouterProfileRepository(
                fluent: fluent,
                legacyPreferences: UserLLMPreferenceRepository(fluent: fluent, logger: logger),
                managedModel: ManagedLLMDefaults.model,
                logger: logger
            ),
            fallback: PlatformFirstTableRouter(),
            budget: RouterTelemetryService(fluent: fluent, logger: logger),
            ensemblesEnabled: false,
            logger: logger,
            credentials: nil,
            registry: ProviderRegistry(
                configs: [ProviderConfig(kind: .anthropic, apiKey: "k", baseURL: nil)],
                adapters: [],
                logger: logger
            ),
            freeLane: nil
        )
    }

    private static let ownGateway = HermesEndpointResolver.Resolution(
        baseURL: URL(string: "http://100.105.117.67:8642")!,
        authHeader: "Bearer gateway-key",
        isUserOverride: true
    )

    @Test
    func `a BYO tenant is routed to their own gateway, not a platform provider`() async throws {
        try await withTestFluent(label: "lv.test.byo.routing") { fluent in
            let decision = await LLMRoutingContext.$currentResolution.withValue(Self.ownGateway) {
                await Self.router(fluent: fluent).pick(forModel: nil, capability: .high, user: Self.user())
            }
            #expect(decision.primary.provider == .hermesGateway)
            #expect(decision.primary.modelID == "hermes-3")
        }
    }

    /// The privacy property: there must be nothing for the transport to fail
    /// over *to*.
    @Test
    func `a BYO tenant has no platform fallback to leak to`() async throws {
        try await withTestFluent(label: "lv.test.byo.routing.fallbacks") { fluent in
            let decision = await LLMRoutingContext.$currentResolution.withValue(Self.ownGateway) {
                await Self.router(fluent: fluent).pick(forModel: nil, capability: .high, user: Self.user())
            }
            #expect(decision.fallbacks.isEmpty)
            #expect(decision.candidates.allSatisfy { $0.provider == .hermesGateway })
            #expect(decision.candidates.contains { $0.provider == .anthropic } == false)
        }
    }

    @Test
    func `the decision still reports itself as deferred to hermes`() async throws {
        try await withTestFluent(label: "lv.test.byo.routing.metadata") { fluent in
            let decision = await LLMRoutingContext.$currentResolution.withValue(Self.ownGateway) {
                await Self.router(fluent: fluent).pick(forModel: nil, capability: .high, user: Self.user())
            }
            #expect(decision.cerberus?.deferredToHermes == true)
            #expect(decision.cerberus?.profileName == "BYO Hermes")
            #expect(decision.cerberus?.predictedCostUsdMicros == 0)
            // The recorded route must match where the request actually goes,
            // or the analytics say Hermes while Anthropic bills us.
            #expect(decision.cerberus?.routes.first?.model == "hermes-3")
        }
    }

    /// A managed tenant is unaffected — the platform table still wins.
    @Test
    func `a managed tenant keeps the platform table`() async throws {
        try await withTestFluent(label: "lv.test.byo.routing.managed") { fluent in
            let managed = HermesEndpointResolver.Resolution(
                baseURL: URL(string: "http://managed.internal:8642")!,
                authHeader: nil,
                isUserOverride: false
            )
            let decision = await LLMRoutingContext.$currentResolution.withValue(managed) {
                await Self.router(fluent: fluent).pick(forModel: nil, capability: .high, user: Self.user())
            }
            #expect(decision.primary.provider == .anthropic)
        }
    }
}
