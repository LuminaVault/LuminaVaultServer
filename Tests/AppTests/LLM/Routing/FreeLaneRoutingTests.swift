@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// End-to-end through `CerberusModelRouter.pick` — the composition the unit
/// suites cannot cover.
///
/// `FreeLanePolicyTests` proves the decision matrix and `FreeLaneGateTests`
/// proves the metering, but neither proves that a real lapsed user's request
/// actually *lands* on the lane, that the decision carries no billable
/// `hermesGateway` fallback, and that it reserves nothing. Those are the
/// properties the cost fix depends on.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct FreeLaneRoutingTests {
    /// Minimal `ModelRouter` standing in for the table cascade. Deliberately
    /// returns a `hermesGateway` route: that is the billable terminal fallback
    /// the free lane must refuse to inherit, so if the lane ever starts
    /// appending it again these tests fail.
    private struct GatewayTableRouter: ModelRouter {
        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            RouteDecision(
                primary: ModelRoute(provider: .hermesGateway, modelID: "hermes-3"),
                fallbacks: [ModelRoute(provider: .hermesGateway, modelID: "hermes-3-small")]
            )
        }
    }

    private static func makeUser(tier: String, override: String = "none") -> User {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return User(
            id: UUID(),
            email: "freelane-\(suffix)@test.luminavault",
            username: "freelane-\(suffix)",
            passwordHash: "",
            tier: tier,
            tierOverride: override
        )
    }

    /// Registry with the platform keys the lane's legs are gated on.
    private static func registry(openRouter: Bool, nvidia: Bool) -> ProviderRegistry {
        var configs: [ProviderConfig] = []
        if openRouter {
            configs.append(ProviderConfig(kind: .openRouter, apiKey: "or-key", baseURL: nil))
        }
        if nvidia {
            configs.append(ProviderConfig(kind: .nvidia, apiKey: "nvapi-key", baseURL: nil))
        }
        return ProviderRegistry(configs: configs, adapters: [], logger: Logger(label: "test.freelane.registry"))
    }

    private static func router(
        fluent: Fluent,
        freeLane: FreeLaneRuntime?,
        openRouterEnabled: Bool = true,
        nvidiaEnabled: Bool = true
    ) -> CerberusModelRouter {
        let logger = Logger(label: "test.freelane.router")
        return CerberusModelRouter(
            profiles: RouterProfileRepository(
                fluent: fluent,
                legacyPreferences: UserLLMPreferenceRepository(fluent: fluent, logger: logger),
                managedModel: ManagedLLMDefaults.model,
                logger: logger
            ),
            fallback: GatewayTableRouter(),
            budget: RouterTelemetryService(fluent: fluent, logger: logger),
            ensemblesEnabled: false,
            logger: logger,
            credentials: nil,
            registry: registry(openRouter: openRouterEnabled, nvidia: nvidiaEnabled),
            freeLane: freeLane
        )
    }

    private static func runtime(fluent: Fluent, perUser: Int64 = 20) -> FreeLaneRuntime {
        FreeLaneRuntime(
            gate: FreeLaneGate(
                fluent: fluent,
                limits: FreeLaneGate.Limits(
                    perUserDaily: perUser,
                    perLegDaily: [.openRouterFree: 1000, .nvidiaDirect: 1000]
                ),
                logger: Logger(label: "test.freelane.gate")
            )
        )
    }

    /// Leg buckets are platform-wide by design, so they leak across tests.
    private static func resetLegBuckets(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM workflow_spend_buckets WHERE scope_key LIKE 'freelane:leg:%'").run()
    }

    private static func prepare(_ fluent: Fluent, user: User) async throws {
        await registerMigrations(on: fluent)
        try await fluent.migrate()
        try await resetLegBuckets(fluent)
        try await user.save(on: fluent.db())
    }

    // MARK: - Streaming: one message, one grant

    /// The property that matters most, end to end through the real router and
    /// the real gate: each streamed message costs exactly one lane grant, and
    /// the lane — not the paid gateway — serves it.
    ///
    /// With an allowance of one, turn 1 must stream and turn 2 must be refused.
    /// Both ways of getting this wrong fail here. The old bypass served turn 1
    /// on the managed gateway (the failing fallback below throws). A double
    /// claim — the stream service picking, then the transport picking again —
    /// would spend the only grant on the first pick and refuse turn 1 itself.
    @Test
    func `each streamed message claims exactly one free-lane grant`() async throws {
        try await withTestFluent(label: "lv.test.freelane.stream.oneclaim") { fluent in
            let user = Self.makeUser(tier: "lapsed")
            try await Self.prepare(fluent, user: user)
            let logger = Logger(label: "test.freelane.stream")

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent, perUser: 1))
            let lane = RoutedLLMTransportStreamingTests.LaneStubAdapter(kind: .openRouter)
            let reserve = RoutedLLMTransportStreamingTests.LaneStubAdapter(kind: .nvidia)
            let transport = RoutedLLMTransport(
                registry: ProviderRegistry(adapters: [lane, reserve], logger: logger),
                router: router,
                currentUser: { user },
                logger: logger
            )
            let service = RoutedHermesLLMStreamService(
                fallback: RoutedLLMTransportStreamingTests.FailingManagedFallback(),
                transport: transport,
                preferences: UserLLMPreferenceRepository(fluent: fluent, logger: logger),
                logger: logger,
                router: router
            )
            let tenant = try user.requireID().uuidString
            let request = ChatRequest(messages: [ChatMessage(role: "user", content: "Hello")], model: nil)

            func turn() async throws -> String {
                try await LLMRoutingContext.withValues({ $0.currentUser = user }) {
                    var text = ""
                    for try await chunk in service.chatStream(sessionKey: tenant, sessionID: "c1", request: request) {
                        text += chunk.delta
                    }
                    return text
                }
            }

            #expect(try await turn() == "free reply")
            #expect(await lane.calls.count == 1)

            await #expect(throws: FreeLaneExhaustedError.self) {
                _ = try await turn()
            }
            #expect(await lane.calls.count == 1, "the refused turn must not have been dispatched")
        }
    }

    // MARK: - The forced lane

    @Test
    func `a lapsed user routes to the free lane and never to the billable gateway`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.lapsed") { fluent in
            let user = Self.makeUser(tier: "lapsed")
            try await Self.prepare(fluent, user: user)

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent))
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.primary.provider == .openRouter)
            #expect(decision.primary.modelID == FreeLaneCatalog.defaultOpenRouterModel)
            // The whole point: no hermesGateway anywhere in the cascade. That
            // fallback spends the gateway's own key and is what made a
            // non-paying user unbounded.
            #expect(!decision.candidates.contains { $0.provider == .hermesGateway })
            // Only free-lane providers may appear as fallbacks: the second
            // OpenRouter `:free` slug (same key, same gate counter) and the NIM
            // reserve. Never a billable provider.
            #expect(decision.fallbacks.allSatisfy { $0.provider == .openRouter || $0.provider == .nvidia })
            #expect(decision.fallbacks.map(\.modelID) == [
                FreeLaneCatalog.defaultOpenRouterSecondaryModel,
                FreeLaneCatalog.defaultNvidiaModel,
            ])
        }
    }

    /// Rule 2b end to end: an *entitled* user who selected BYOK and stored no
    /// key used to reach `byokKeysRequiredDecision` and get a 403. They now land
    /// on the lane like anyone else without a funding source.
    @Test
    func `an entitled byok user with no keys lands on the free lane, not a 403`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.byoknokey") { fluent in
            let user = Self.makeUser(tier: "pro")
            try await Self.prepare(fluent, user: user)

            let preference = UserLLMPreference()
            preference.tenantID = try user.requireID()
            preference.mode = "byok"
            preference.primaryProvider = "anthropic"
            preference.primaryModel = "claude-opus-4-7"
            preference.fallbackChain = .init(steps: [])
            try await preference.save(on: fluent.db())

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent))
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.primary.provider == .openRouter)
            #expect(decision.primary.modelID == FreeLaneCatalog.defaultOpenRouterModel)
            // The lane is platform-funded, so it presents as managed.
            #expect(decision.credentialMode == .managed)
            #expect(decision.cerberus?.freeLaneExhausted == false)
            #expect(!decision.candidates.contains { $0.provider == .hermesGateway })
        }
    }

    /// The lane is platform-funded, so it must present as managed — which is
    /// also what makes `ModelDisclosurePolicy` hide the model id.
    @Test
    func `the free lane presents as managed and reserves nothing`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.managed") { fluent in
            let user = Self.makeUser(tier: "lapsed")
            try await Self.prepare(fluent, user: user)

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent))
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.credentialMode == .managed)
            let cerberus = try #require(decision.cerberus)
            #expect(cerberus.mode == .managed)
            #expect(ModelDisclosure.forBrainMode(cerberus.mode) == .hidden)
            #expect(cerberus.predictedCostUsdMicros == 0)
            #expect(cerberus.budgetReservationUsdMicros == 0)
            #expect(cerberus.budgetDenied == false)
            #expect(cerberus.freeLaneExhausted == false)
        }
    }

    // MARK: - Who is spared

    @Test(arguments: ["pro", "ultimate", "trial"])
    func `entitled tiers keep their own routing`(tier: String) async throws {
        try await withTestFluent(label: "lv.test.freelane.route.entitled.\(tier)") { fluent in
            let user = Self.makeUser(tier: tier)
            try await Self.prepare(fluent, user: user)

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent))
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.primary.modelID != FreeLaneCatalog.defaultOpenRouterModel)
            #expect(decision.cerberus?.freeLaneExhausted != true)
        }
    }

    /// An ops-granted Pro must be indistinguishable from a paid one.
    @Test
    func `a tier_override rescues a lapsed user from the lane`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.override") { fluent in
            let user = Self.makeUser(tier: "lapsed", override: "pro")
            try await Self.prepare(fluent, user: user)

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent))
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.primary.modelID != FreeLaneCatalog.defaultOpenRouterModel)
        }
    }

    // MARK: - Emergency lane

    /// Losing the platform OpenRouter key degrades *everyone*, including payers
    /// — deliberately, because the alternative is no answer at all.
    @Test
    func `a platform outage degrades a paying user onto the lane`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.outage") { fluent in
            let user = Self.makeUser(tier: "pro")
            try await Self.prepare(fluent, user: user)

            let router = Self.router(
                fluent: fluent,
                freeLane: Self.runtime(fluent: fluent),
                openRouterEnabled: false
            )
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            // Leg 1 is unavailable (no platform key), so the lane serves leg 2.
            #expect(decision.primary.provider == .nvidia)
            #expect(decision.primary.modelID == FreeLaneCatalog.defaultNvidiaModel)
            #expect(!decision.candidates.contains { $0.provider == .hermesGateway })
        }
    }

    // MARK: - Exhaustion

    @Test
    func `an exhausted lane surfaces a retry hint instead of a route`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.exhausted") { fluent in
            let user = Self.makeUser(tier: "lapsed")
            try await Self.prepare(fluent, user: user)

            // Grace of 1: the first turn is served, the second is refused.
            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent, perUser: 1))
            _ = await router.pick(forModel: nil, capability: .medium, user: user)
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            let cerberus = try #require(decision.cerberus)
            #expect(cerberus.freeLaneExhausted)
            #expect(cerberus.freeLaneRetryAfterSeconds > 0)
            // The transport turns this into 429 free_lane_exhausted before
            // dispatching, so nothing is spent on the way out.
            #expect(cerberus.budgetReservationUsdMicros == 0)
        }
    }

    /// Both legs unfunded is not a silent fall-through to the gateway — that
    /// fall-through is the bug the lane exists to remove. Nor is it
    /// exhaustion, which is what it used to report: the user was told they had
    /// "used today's free messages" when no free provider was configured at
    /// all and they had used none. It is unavailability, it charges nothing,
    /// and it offers the ways out that are real for this user.
    @Test
    func `no funded leg is unavailability rather than a gateway fallback`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.nolegs") { fluent in
            let user = Self.makeUser(tier: "lapsed")
            try await Self.prepare(fluent, user: user)

            let runtime = Self.runtime(fluent: fluent, perUser: 5)
            let router = Self.router(
                fluent: fluent,
                freeLane: runtime,
                openRouterEnabled: false,
                nvidiaEnabled: false
            )
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.cerberus?.freeLaneUnavailable == true)
            #expect(decision.cerberus?.freeLaneExhausted == false)
            #expect(decision.fallbacks.isEmpty)
            #expect(try await runtime.gate.remainingToday(tenantID: user.requireID()) == 5, "no grant may be charged")
            // A lapsed user can pay or bring a key; both are real ways out.
            #expect(decision.cerberus?.freeLaneActions == ["upgrade", "add_key"])
        }
    }

    /// An entitled user who picked BYOK and stored no key reaches the lane by
    /// rule 2b. Telling them to upgrade would be wrong — they already pay — but
    /// managed inference is available to them, so that is the offer.
    @Test
    func `an unavailable lane offers a paying byok user managed, not an upgrade`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.nolegs.pro") { fluent in
            let user = Self.makeUser(tier: "pro")
            try await Self.prepare(fluent, user: user)
            let preference = UserLLMPreference()
            preference.tenantID = try user.requireID()
            preference.mode = "byok"
            preference.primaryProvider = "anthropic"
            preference.primaryModel = "claude-opus-4-7"
            preference.fallbackChain = .init(steps: [])
            try await preference.save(on: fluent.db())

            let router = Self.router(
                fluent: fluent,
                freeLane: Self.runtime(fluent: fluent),
                openRouterEnabled: false,
                nvidiaEnabled: false
            )
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.cerberus?.freeLaneUnavailable == true)
            #expect(decision.cerberus?.freeLaneActions == ["add_key", "switch_to_managed"])
        }
    }

    /// Exhaustion is the same question as unavailability: the ways out must be
    /// the ones that are real for this user. A paying BYOK user without a key
    /// who spends the lane is offered managed, not an upgrade.
    @Test
    func `an exhausted lane offers a paying byok user managed, not an upgrade`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.exhausted.pro") { fluent in
            let user = Self.makeUser(tier: "pro")
            try await Self.prepare(fluent, user: user)
            let preference = UserLLMPreference()
            preference.tenantID = try user.requireID()
            preference.mode = "byok"
            preference.primaryProvider = "anthropic"
            preference.primaryModel = "claude-opus-4-7"
            preference.fallbackChain = .init(steps: [])
            try await preference.save(on: fluent.db())

            let router = Self.router(fluent: fluent, freeLane: Self.runtime(fluent: fluent, perUser: 1))
            _ = await router.pick(forModel: nil, capability: .medium, user: user)
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            let error = try #require(decision.cerberus?.preflightError() as? FreeLaneExhaustedError)
            #expect(error.actions == ["add_key", "switch_to_managed"])
        }
    }

    // MARK: - Kill switch

    @Test
    func `the kill switch restores pre-lane routing`() async throws {
        try await withTestFluent(label: "lv.test.freelane.route.killswitch") { fluent in
            let user = Self.makeUser(tier: "lapsed")
            try await Self.prepare(fluent, user: user)

            let router = Self.router(fluent: fluent, freeLane: nil)
            let decision = await router.pick(forModel: nil, capability: .medium, user: user)

            #expect(decision.primary.modelID != FreeLaneCatalog.defaultOpenRouterModel)
            #expect(decision.cerberus?.freeLaneExhausted != true)
        }
    }
}
