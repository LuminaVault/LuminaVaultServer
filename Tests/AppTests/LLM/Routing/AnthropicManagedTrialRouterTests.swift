@testable import App
import Configuration
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// The Haiku trial as a routing decision: Anthropic in front of platform-paid
/// traffic, the original pick kept behind it, and nothing else touched.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct AnthropicManagedTrialRouterTests {
    private static let trial = AnthropicManagedTrialConfig(apiKey: "trial-key")
    private static let trialRoute = ModelRoute(provider: .anthropic, modelID: "claude-haiku-5-5")
    private static let gateway = ModelRoute(provider: .hermesGateway, modelID: "hermes-3")
    private static let openRouter = ModelRoute(provider: .openRouter, modelID: "deepseek/deepseek-v4-flash")

    private static func metadata(
        mode: LLMBrainMode = .managed,
        strategy: RouterActionKind = .sequential,
        deferredToHermes: Bool = false,
        isFreeLane: Bool = false,
        budgetDenied: Bool = false
    ) -> CerberusDecisionMetadata {
        let tenantID = UUID()
        return CerberusDecisionMetadata(
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
            strategy: strategy,
            parallelStrategy: nil,
            participants: nil,
            routes: [RouterModelRouteDTO(provider: .openRouter, model: openRouter.modelID)],
            synthesisRoute: nil,
            minimumSuccessfulResults: 1,
            retryPolicy: .fast,
            predictedCostUsdMicros: 0,
            budgetReservationUsdMicros: 0,
            budgetDenied: budgetDenied,
            mode: mode,
            routingPolicy: .autoSmart,
            deferredToHermes: deferredToHermes,
            isFreeLane: isFreeLane
        )
    }

    private static func apply(
        _ decision: RouteDecision,
        config: AnthropicManagedTrialConfig = trial,
        contextMode: LLMBrainMode? = nil,
        hermesOverride: Bool = false
    ) -> RouteDecision {
        AnthropicManagedTrialRouter.apply(
            config,
            to: decision,
            contextCredentialMode: contextMode,
            isUserHermesOverride: hermesOverride
        )
    }

    // MARK: - Applies

    @Test
    func `managed decisions get anthropic first and keep the original chain behind it`() {
        let cerberus = Self.metadata()
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [Self.gateway], cerberus: cerberus, credentialMode: .managed)
        let result = Self.apply(decision)
        #expect(result.primary == Self.trialRoute)
        #expect(result.fallbacks == [Self.openRouter, Self.gateway])
        #expect(result.cerberus == cerberus, "budget, telemetry and preflight still read the original metadata")
        #expect(result.credentialMode == .managed)
        #expect(result.managedTrialPrepended)
    }

    @Test
    func `internal work with no declared mode is platform-paid and gets the trial`() {
        let decision = RouteDecision(primary: Self.gateway, fallbacks: [])
        let result = Self.apply(decision)
        #expect(result.candidates == [Self.trialRoute, Self.gateway])
        #expect(result.credentialMode == nil, "the original intent is preserved, not rewritten")
    }

    @Test
    func `free lane decisions get the trial under the default scope`() {
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [], cerberus: Self.metadata(isFreeLane: true), credentialMode: .managed)
        #expect(Self.apply(decision).primary == Self.trialRoute)
    }

    @Test
    func `the configured model is the one prepended`() {
        let config = AnthropicManagedTrialConfig(apiKey: "k", model: "claude-haiku-5-5-preview")
        let result = Self.apply(RouteDecision(primary: Self.gateway, fallbacks: []), config: config)
        #expect(result.primary == ModelRoute(provider: .anthropic, modelID: "claude-haiku-5-5-preview"))
    }

    @Test
    func `the trial route is never listed twice`() {
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [Self.trialRoute, Self.gateway], credentialMode: .managed)
        #expect(Self.apply(decision).candidates == [Self.trialRoute, Self.openRouter, Self.gateway])
    }

    // MARK: - Leaves alone

    @Test
    func `byok decisions are returned unchanged`() {
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [], credentialMode: .byok)
        #expect(Self.apply(decision) == decision)
    }

    @Test
    func `a byok cerberus mode or task-local mode is respected`() {
        let viaCerberus = RouteDecision(primary: Self.openRouter, fallbacks: [], cerberus: Self.metadata(mode: .byok))
        #expect(Self.apply(viaCerberus) == viaCerberus)
        let viaContext = RouteDecision(primary: Self.openRouter, fallbacks: [])
        #expect(Self.apply(viaContext, contextMode: .byok) == viaContext)
    }

    @Test
    func `byo hermes is left alone`() {
        let deferred = RouteDecision(primary: Self.gateway, fallbacks: [], cerberus: Self.metadata(deferredToHermes: true), credentialMode: .byok)
        #expect(Self.apply(deferred) == deferred)
        let override = RouteDecision(primary: Self.gateway, fallbacks: [])
        #expect(Self.apply(override, hermesOverride: true) == override)
    }

    @Test
    func `ensembles are left alone`() {
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [], cerberus: Self.metadata(strategy: .ensemble), credentialMode: .managed)
        #expect(Self.apply(decision) == decision)
    }

    @Test
    func `free lane decisions are left alone when scope is paid`() {
        let config = AnthropicManagedTrialConfig(apiKey: "k", scope: .paid)
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [], cerberus: Self.metadata(isFreeLane: true), credentialMode: .managed)
        #expect(Self.apply(decision, config: config) == decision)
        let paid = RouteDecision(primary: Self.openRouter, fallbacks: [], cerberus: Self.metadata(), credentialMode: .managed)
        #expect(Self.apply(paid, config: config).primary == Self.trialRoute)
    }

    @Test
    func `a decision the transport will refuse is left alone`() {
        let decision = RouteDecision(primary: Self.openRouter, fallbacks: [], cerberus: Self.metadata(budgetDenied: true), credentialMode: .managed)
        #expect(Self.apply(decision) == decision)
    }

    // MARK: - Gateway stream

    @Test
    func `removing the trial route restores the original decision`() {
        let cerberus = Self.metadata()
        let original = RouteDecision(primary: Self.openRouter, fallbacks: [Self.gateway], cerberus: cerberus, credentialMode: .managed)
        let restored = Self.apply(original).removingManagedTrialRoute()
        #expect(restored == original)
    }

    @Test
    func `removing is a no-op on a decision the trial did not touch`() {
        let anthropicPrimary = RouteDecision(primary: Self.trialRoute, fallbacks: [Self.gateway], credentialMode: .managed)
        #expect(anthropicPrimary.removingManagedTrialRoute() == anthropicPrimary)
    }

    // MARK: - Router

    @Test
    func `pick wraps the inner router`() async {
        let inner = RoutedLLMTransportFallbackTests.FixedRouter(
            decision: RouteDecision(primary: Self.gateway, fallbacks: [], credentialMode: .managed)
        )
        let router = AnthropicManagedTrialRouter(inner: inner, config: Self.trial)
        let decision = await router.pick(forModel: nil, capability: .medium, user: nil)
        #expect(decision.candidates == [Self.trialRoute, Self.gateway])
    }

    // MARK: - Config

    private static func reader(env: [String: String]) -> ConfigReader {
        ConfigReader(providers: [EnvironmentVariablesProvider(environmentVariables: env)])
    }

    @Test
    func `the env contract maps onto the trial config`() throws {
        let config = try #require(AnthropicManagedTrialConfig.load(from: Self.reader(env: [
            "ANTHROPIC_API_KEY": "sk-ant-trial",
            "ANTHROPIC_FIRST": "true",
            "ANTHROPIC_MODEL": "claude-haiku-5-5",
            "ANTHROPIC_EFFORT": "LOW",
            "ANTHROPIC_THINKING": "disabled",
            "ANTHROPIC_SCOPE": "paid",
        ])))
        #expect(config.apiKey == "sk-ant-trial")
        #expect(config.model == "claude-haiku-5-5")
        #expect(config.effort == "low")
        #expect(config.thinking == .disabled)
        #expect(config.scope == .paid)
    }

    @Test
    func `defaults apply when only the key and flag are set`() throws {
        let config = try #require(AnthropicManagedTrialConfig.load(from: Self.reader(env: [
            "ANTHROPIC_API_KEY": "sk-ant-trial",
            "ANTHROPIC_FIRST": "true",
            "ANTHROPIC_EFFORT": "turbo",
        ])))
        #expect(config.model == AnthropicManagedTrialConfig.defaultModel)
        #expect(config.effort == nil, "an unknown effort falls back to the model default")
        #expect(config.thinking == .adaptive)
        #expect(config.scope == .all)
    }

    @Test
    func `no trial without the flag or without a key`() {
        #expect(AnthropicManagedTrialConfig.load(from: Self.reader(env: ["ANTHROPIC_API_KEY": "sk-ant-trial"])) == nil)
        #expect(AnthropicManagedTrialConfig.load(from: Self.reader(env: [
            "ANTHROPIC_API_KEY": "sk-ant-trial",
            "ANTHROPIC_FIRST": "false",
        ])) == nil)
        #expect(AnthropicManagedTrialConfig.load(from: Self.reader(env: ["ANTHROPIC_FIRST": "true"])) == nil)
    }
}

/// `ANTHROPIC_API_KEY` must feed the adapter only. If it enabled `.anthropic`
/// in `ProviderRegistry`, `TableModelRouter` would put Sonnet and Opus at the
/// front of pro traffic and `AvailableModelPoolBuilder` would add Opus to the
/// Auto pools — on a $20 trial key.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct AnthropicTrialKeyWiringTests {
    @Test
    func `the trial key alias does not enable anthropic in the registry`() async {
        let reader = ConfigReader(providers: [EnvironmentVariablesProvider(environmentVariables: [
            "ANTHROPIC_API_KEY": "sk-ant-trial",
            "ANTHROPIC_FIRST": "true",
        ])])
        let registry = ProviderRegistry.from(reader: reader, adapters: [], logger: Logger(label: "test"))
        #expect(await registry.isEnabled(.anthropic) == false)
        #expect(!ProviderRegistry.loadConfigs(from: reader).contains { $0.kind == .anthropic })
        #expect(AnthropicManagedTrialConfig.resolveAPIKey(from: reader) == "sk-ant-trial")
    }

    @Test
    func `a registry key still wins over the trial alias`() {
        let reader = ConfigReader(providers: [EnvironmentVariablesProvider(environmentVariables: [
            "LLM_PROVIDER_ANTHROPIC_API_KEY": "sk-ant-registry",
            "ANTHROPIC_API_KEY": "sk-ant-trial",
        ])])
        #expect(AnthropicManagedTrialConfig.resolveAPIKey(from: reader) == "sk-ant-registry")
    }

    /// With no registry key, the trial still never reaches the table router.
    @Test
    func `pro table routing does not offer anthropic on the trial key`() async {
        let reader = ConfigReader(providers: [EnvironmentVariablesProvider(environmentVariables: [
            "ANTHROPIC_API_KEY": "sk-ant-trial",
            "ANTHROPIC_FIRST": "true",
        ])])
        let registry = ProviderRegistry.from(
            reader: reader,
            adapters: [AnthropicAdapter(
                apiKey: "",
                logger: Logger(label: "test"),
                managedTrial: AnthropicManagedTrialConfig.load(from: reader)
            )],
            logger: Logger(label: "test")
        )
        let table = TableModelRouter(registry: registry, hermesDefaultModel: "hermes-3")
        let user = User(email: "pro@example.com", username: "pro", passwordHash: "x", tier: "pro")
        let decision = await table.pick(forModel: nil, capability: .high, user: user)
        #expect(!decision.candidates.contains { $0.provider == .anthropic })
    }
}
