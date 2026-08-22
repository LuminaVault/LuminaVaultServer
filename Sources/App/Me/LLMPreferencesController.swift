import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension LLMPreferencesGetResponse: @retroactive ResponseEncodable {}

/// HER-252 — `/v1/me/preferences/llm` GET + PUT. Row absent ⇒ GET
/// returns the deployment's effective managed route so clients have something
/// authoritative to render. Managed PUTs ignore client-supplied provider/model
/// policy and persist the deployment defaults. BYOK PUTs replace the whole row;
/// no FK validation verifies that the user owns credentials for the chosen
/// provider (the router skips providers without credentials at runtime).
struct LLMPreferencesController {
    let repository: UserLLMPreferenceRepository
    let routerProfiles: RouterProfileRepository
    let defaultPrimaryProvider: ProviderID
    let defaultPrimaryModel: String
    let logger: Logger
    /// Free-lane inputs. Both default to "lane off", so every existing test
    /// construction keeps its current behaviour.
    let freeLaneEnabled: Bool
    let platformPaidManagedAvailable: @Sendable () async -> Bool
    let hasUsableCredential: @Sendable (UUID) async -> Bool

    init(
        repository: UserLLMPreferenceRepository,
        routerProfiles: RouterProfileRepository,
        defaultPrimaryProvider: ProviderID = ManagedLLMDefaults.provider,
        defaultPrimaryModel: String = ManagedLLMDefaults.model,
        logger: Logger,
        freeLaneEnabled: Bool = false,
        platformPaidManagedAvailable: @escaping @Sendable () async -> Bool = { true },
        hasUsableCredential: @escaping @Sendable (UUID) async -> Bool = { _ in false }
    ) {
        self.repository = repository
        self.routerProfiles = routerProfiles
        self.defaultPrimaryProvider = defaultPrimaryProvider
        self.defaultPrimaryModel = defaultPrimaryModel
        self.logger = logger
        self.freeLaneEnabled = freeLaneEnabled
        self.platformPaidManagedAvailable = platformPaidManagedAvailable
        self.hasUsableCredential = hasUsableCredential
    }

    /// The managed shape. What a forced-free-lane user is told, and it is true:
    /// the lane *is* managed, so `ModelDisclosurePolicy` hides the model id and
    /// the pane renders the generic brain label.
    private var managedWire: LLMPreferencesGetResponse {
        LLMPreferencesGetResponse(
            mode: .managed,
            primaryProvider: defaultPrimaryProvider,
            primaryModel: ModelDisclosurePolicy.genericBrainName,
            fallbackChain: []
        )
    }

    /// Report the *effective* route rather than the stored one.
    ///
    /// The router is the sole authority on who pays (`FreeLanePolicy`), so no
    /// write path rejects anything — a lapsed user's stored BYOK preference is
    /// persisted intact and takes effect the moment they upgrade or add a key.
    /// Reads canonicalise instead, so the pane never claims a route the user
    /// will not actually get.
    private func effectiveWire(
        _ snapshot: UserLLMPreferenceRepository.Snapshot?,
        user: User
    ) async -> LLMPreferencesGetResponse {
        guard let snapshot else { return managedWire }
        let requestedMode = Self.toWireMode(snapshot.mode)
        guard freeLaneEnabled, let tenantID = try? user.requireID() else {
            return toWire(snapshot) ?? managedWire
        }
        let honoured = await FreeLanePolicy.honoursUserChoice(.init(
            effectiveTier: EntitlementChecker.effectiveTier(
                tier: user.tierEnum,
                override: user.tierOverrideEnum
            ),
            requestedMode: requestedMode,
            hasUsableUserCredential: hasUsableCredential(tenantID),
            platformPaidManagedAvailable: platformPaidManagedAvailable(),
            freeLaneEnabled: freeLaneEnabled
        ))
        return honoured ? (toWire(snapshot) ?? managedWire) : managedWire
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: get)
        router.put(use: put)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> LLMPreferencesGetResponse {
        // requireIdentity, not requireTenantID: the effective route depends on
        // the user's tier and override, not just their tenant.
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let snapshot = try await repository.get(tenantID: tenantID)
        return await effectiveWire(snapshot, user: user)
    }

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> LLMPreferencesGetResponse {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: LLMPreferencesPutRequest.self, context: ctx)

        // Managed policy belongs to the backend. Older clients still send a
        // provider/model pair, but those fields must never pin the platform to
        // a stale model. BYOK remains fully user-configurable.
        let primaryProvider: ProviderID
        let primaryModel: String
        let fallbackChain: [ModelRouteDTO]
        let allowedProviders: [ProviderID]
        let blockedProviders: [ProviderID]
        switch body.mode {
        case .managed:
            primaryProvider = defaultPrimaryProvider
            primaryModel = defaultPrimaryModel
            fallbackChain = []
            allowedProviders = []
            blockedProviders = []
        case .byok:
            guard !body.primaryModel.isEmpty else {
                throw HTTPError(.badRequest, message: "primary_model_required")
            }
            for step in body.fallbackChain where step.model.isEmpty {
                throw HTTPError(.badRequest, message: "fallback_model_required")
            }
            primaryProvider = body.primaryProvider
            primaryModel = body.primaryModel
            fallbackChain = body.fallbackChain
            allowedProviders = body.allowedProviders
            blockedProviders = body.blockedProviders
        }

        let snapshot: UserLLMPreferenceRepository.Snapshot
        do {
            snapshot = try await repository.upsert(
                tenantID: tenantID,
                mode: Self.toModelMode(body.mode),
                primaryProvider: Self.toKind(primaryProvider),
                primaryModel: primaryModel,
                fallbackChain: fallbackChain.map {
                    UserLLMPreferenceRepository.Snapshot.Step(
                        provider: Self.toKind($0.provider),
                        model: $0.model
                    )
                },
                allowedProviders: allowedProviders.map(Self.toKind),
                blockedProviders: blockedProviders.map(Self.toKind)
            )
            try await routerProfiles.synchronizeDefault(
                tenantID: tenantID,
                mode: body.mode,
                primaryProvider: primaryProvider,
                primaryModel: primaryModel,
                fallbackChain: fallbackChain,
                allowedProviders: allowedProviders,
                blockedProviders: blockedProviders
            )
        } catch {
            logger.error("llm preference upsert failed: \(error)")
            throw HTTPError(.internalServerError, message: "preference_save_failed")
        }
        guard toWire(snapshot) != nil else {
            // Should be unreachable: PUT path goes through `toKind` which
            // round-trips a valid ProviderID. A nil here means the row's
            // primary provider isn't in the user-facing set, which only
            // happens if the schema is hand-edited.
            throw HTTPError(.internalServerError, message: "preference_unmappable")
        }
        // The write is persisted verbatim above; the *response* reports what
        // the router will actually do, so a forced-free-lane user is not told
        // their BYOK selection took effect when it did not.
        guard let user = try? ctx.requireIdentity() else { return toWire(snapshot) ?? managedWire }
        return await effectiveWire(snapshot, user: user)
    }

    // MARK: - Mapping helpers

    private static func toKind(_ id: ProviderID) -> ProviderKind {
        switch id {
        case .xai: .xai
        case .nvidia: .nvidia
        case .anthropic: .anthropic
        case .openai: .openai
        case .ollama: .ollama
        case .openRouter: .openRouter
        case .gemini: .gemini
        case .nous: .nous
        case .custom: .custom
        }
    }

    private static func toModelMode(_ wire: LLMBrainMode) -> UserLLMPreference.Mode {
        switch wire {
        case .managed: .managed
        case .byok: .byok
        }
    }

    private static func toWireMode(_ model: UserLLMPreference.Mode) -> LLMBrainMode {
        switch model {
        case .managed: .managed
        case .byok: .byok
        }
    }

    private func toWire(_ snapshot: UserLLMPreferenceRepository.Snapshot) -> LLMPreferencesGetResponse? {
        if snapshot.mode == .managed {
            // Managed tenants never see the concrete model id — the pane
            // renders the generic brain label (ModelDisclosurePolicy). The
            // effective model stays server-owned.
            return LLMPreferencesGetResponse(
                mode: .managed,
                primaryProvider: defaultPrimaryProvider,
                primaryModel: ModelDisclosurePolicy.genericBrainName,
                fallbackChain: []
            )
        }
        guard let primary = snapshot.primaryProvider.toShared() else {
            return nil
        }
        let chain = snapshot.fallbackChain.compactMap { step -> ModelRouteDTO? in
            guard let id = step.provider.toShared() else { return nil }
            return ModelRouteDTO(provider: id, model: step.model)
        }
        return LLMPreferencesGetResponse(
            mode: Self.toWireMode(snapshot.mode),
            primaryProvider: primary,
            primaryModel: snapshot.primaryModel,
            fallbackChain: chain,
            allowedProviders: snapshot.allowedProviders.compactMap { $0.toShared() },
            blockedProviders: snapshot.blockedProviders.compactMap { $0.toShared() }
        )
    }
}
