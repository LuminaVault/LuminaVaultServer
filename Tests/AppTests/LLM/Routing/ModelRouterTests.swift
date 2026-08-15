@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// HER-161 — full routing matrix coverage for `TableModelRouter`.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct ModelRouterTests {
    private static func registry(enabled: [ProviderKind]) -> ProviderRegistry {
        let configs = enabled
            .filter { $0 != .hermesGateway }
            .map { ProviderConfig(kind: $0, apiKey: "test-key", baseURL: nil) }
        return ProviderRegistry(
            configs: configs,
            adapters: enabled.contains(.hermesGateway) ? [StubAdapter(kind: .hermesGateway)] : [],
            logger: Logger(label: "test")
        )
    }

    private struct StubAdapter: ProviderAdapter {
        let kind: ProviderKind
        func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            Data()
        }
    }

    private static func user(tier: UserTier, override: TierOverride = .none, privacyNoCN: Bool = false) -> User {
        let u = User(
            id: UUID(),
            email: "x@example.com",
            username: "x",
            passwordHash: "h",
            tier: tier.rawValue,
            tierOverride: override.rawValue
        )
        u.privacyNoCNOrigin = privacyNoCN
        return u
    }

    // MARK: - Pro tier matrix

    @Test
    func `pro high routes sonnet then opus then gpt5`() async {
        let registry = Self.registry(enabled: [.anthropic, .openai, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .high, user: Self.user(tier: .pro))

        #expect(decision.primary == ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4-6"))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .anthropic, modelID: "claude-opus-4-7")))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .openai, modelID: "gpt-5")))
        #expect(decision.fallbacks.last == ModelRoute(provider: .hermesGateway, modelID: "hermes-3"))
    }

    @Test
    func `pro medium routes sonnet then gemini 25 pro`() async {
        let registry = Self.registry(enabled: [.anthropic, .gemini, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .medium, user: Self.user(tier: .pro))

        #expect(decision.primary == ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4-6"))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .gemini, modelID: "gemini-2.5-pro")))
    }

    // MARK: - Free lane
    //
    // The free tier used to name Together/Groq/Gemini models whose API keys are
    // unset in every deployment. Those rows were filtered out and the tier
    // collapsed to the Hermes gateway — so "free" was quietly billing the
    // platform's gateway key. `FreeLaneCatalog` replaced the table with two
    // genuinely $0 legs, and these tests pin that.

    @Test
    func `free tier routes the openrouter free leg then nvidia`() async {
        let registry = Self.registry(enabled: [.openRouter, .nvidia, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .high, user: Self.user(tier: .trial))

        // OpenRouter `:free` goes first: it consumes no balance, so it is the
        // renewable leg. NVIDIA burns finite signup credits and is the reserve.
        #expect(decision.primary == ModelRoute(provider: .openRouter, modelID: FreeLaneCatalog.defaultOpenRouterModel))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .nvidia, modelID: FreeLaneCatalog.defaultNvidiaModel)))
    }

    @Test
    func `the free lane is the same at every capability level`() async {
        // Capability tiers exist to spend more on harder work. There is nothing
        // to spend on the free lane, so all three levels resolve identically.
        let registry = Self.registry(enabled: [.openRouter, .nvidia, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")

        for capability in [LLMCapabilityLevel.high, .medium, .low] {
            let decision = await router.pick(forModel: nil, capability: capability, user: Self.user(tier: .trial))
            #expect(
                decision.primary == ModelRoute(provider: .openRouter, modelID: FreeLaneCatalog.defaultOpenRouterModel),
                "capability \(capability)"
            )
        }
    }

    @Test
    func `free tier falls back to hermes when neither free leg is configured`() async {
        let registry = Self.registry(enabled: [.hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .high, user: Self.user(tier: .trial))

        #expect(decision.primary == ModelRoute(provider: .hermesGateway, modelID: "hermes-3"))
    }

    // MARK: - Privacy filter (HER-176)

    @Test
    func `privacy no CN origin leaves the free lane intact`() async {
        // The old free lane was deepseek + kimi, both CN-origin, so this flag
        // used to collapse free users onto the Hermes gateway. Both current
        // legs are Nemotron, so a privacy-conscious free user now keeps a
        // working zero-cost route instead of silently costing us money.
        let registry = Self.registry(enabled: [.openRouter, .nvidia, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(
            forModel: nil,
            capability: .high,
            user: Self.user(tier: .trial, privacyNoCN: true)
        )

        #expect(decision.primary == ModelRoute(provider: .openRouter, modelID: FreeLaneCatalog.defaultOpenRouterModel))
        let cnRoutes = decision.candidates.filter { ModelOriginRegistry.isCNOrigin($0.modelID) }
        #expect(cnRoutes.isEmpty)
    }

    @Test
    func `privacy no CN origin keeps non CN routes intact for pro`() async {
        let registry = Self.registry(enabled: [.anthropic, .openai, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(
            forModel: nil,
            capability: .high,
            user: Self.user(tier: .pro, privacyNoCN: true)
        )

        #expect(decision.primary.provider == .anthropic)
    }

    // MARK: - Disabled provider handling

    @Test
    func `disabled providers fall through to hermes`() async {
        // No external providers configured — only hermes adapter registered.
        let registry = Self.registry(enabled: [.hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .high, user: Self.user(tier: .pro))

        #expect(decision.primary == ModelRoute(provider: .hermesGateway, modelID: "hermes-3"))
        #expect(decision.fallbacks.isEmpty)
    }

    // MARK: - Ultimate tier maps to pro

    @Test
    func `ultimate tier uses pro routing table`() async {
        let registry = Self.registry(enabled: [.anthropic, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .medium, user: Self.user(tier: .ultimate))

        #expect(decision.primary.provider == .anthropic)
    }

    // MARK: - Tier override wins

    @Test
    func `ultimate override on lapsed user still routes pro`() async {
        let registry = Self.registry(enabled: [.anthropic, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(
            forModel: nil,
            capability: .high,
            user: Self.user(tier: .lapsed, override: .ultimate)
        )

        #expect(decision.primary.provider == .anthropic)
    }

    // MARK: - Nil user defaults to free

    @Test
    func `nil user defaults to free routing`() async {
        let registry = Self.registry(enabled: [.openRouter, .nvidia, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .medium, user: nil)

        #expect(decision.primary == ModelRoute(provider: .openRouter, modelID: FreeLaneCatalog.defaultOpenRouterModel))
    }
}
