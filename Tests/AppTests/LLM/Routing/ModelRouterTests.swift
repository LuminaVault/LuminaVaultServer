@testable import App
import Foundation
import Logging
import Testing

/// HER-161 — full routing matrix coverage for `TableModelRouter`.
@Suite(.serialized)
struct ModelRouterTests {
    private static func registry(enabled: [ProviderKind]) -> ProviderRegistry {
        let configs = enabled
            .filter { $0 != .hermesGateway }
            .map { ProviderConfig(kind: $0, apiKey: "test-key", baseURL: nil) }
        return ProviderRegistry(
            configs: configs,
            adapters: enabled.contains(.hermesGateway) ? [StubAdapter(kind: .hermesGateway)] : [],
            logger: Logger(label: "test"),
        )
    }

    private struct StubAdapter: ProviderAdapter {
        let kind: ProviderKind
        func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
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
            tierOverride: override.rawValue,
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

        #expect(decision.primary == ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4.6"))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .anthropic, modelID: "claude-opus-4.7")))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .openai, modelID: "gpt-5")))
        #expect(decision.fallbacks.last == ModelRoute(provider: .hermesGateway, modelID: "hermes-3"))
    }

    @Test
    func `pro medium routes sonnet then gemini 25 pro`() async {
        let registry = Self.registry(enabled: [.anthropic, .gemini, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .medium, user: Self.user(tier: .pro))

        #expect(decision.primary == ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4.6"))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .gemini, modelID: "gemini-2.5-pro")))
    }

    // MARK: - Free tier matrix

    @Test
    func `free high routes deepseek then kimi`() async {
        let registry = Self.registry(enabled: [.together, .groq, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .high, user: Self.user(tier: .trial))

        #expect(decision.primary == ModelRoute(provider: .together, modelID: "deepseek-v3.2"))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .groq, modelID: "kimi-k2")))
    }

    @Test
    func `free medium routes gemini flash then deepseek`() async {
        let registry = Self.registry(enabled: [.gemini, .together, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .medium, user: Self.user(tier: .trial))

        #expect(decision.primary == ModelRoute(provider: .gemini, modelID: "gemini-flash"))
        #expect(decision.fallbacks.contains(ModelRoute(provider: .together, modelID: "deepseek")))
    }

    // MARK: - Privacy filter (HER-176)

    @Test
    func `privacy no CN origin drops deepseek and kimi from free high`() async {
        let registry = Self.registry(enabled: [.together, .groq, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(
            forModel: nil,
            capability: .high,
            user: Self.user(tier: .trial, privacyNoCN: true),
        )

        // deepseek-v3.2 + kimi-k2 are CN-origin; only hermes survives.
        #expect(decision.primary == ModelRoute(provider: .hermesGateway, modelID: "hermes-3"))
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
            user: Self.user(tier: .pro, privacyNoCN: true),
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
            user: Self.user(tier: .lapsed, override: .ultimate),
        )

        #expect(decision.primary.provider == .anthropic)
    }

    // MARK: - Nil user defaults to free

    @Test
    func `nil user defaults to free routing`() async {
        let registry = Self.registry(enabled: [.gemini, .together, .hermesGateway])
        let router = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let decision = await router.pick(forModel: nil, capability: .medium, user: nil)

        #expect(decision.primary == ModelRoute(provider: .gemini, modelID: "gemini-flash"))
    }
}
