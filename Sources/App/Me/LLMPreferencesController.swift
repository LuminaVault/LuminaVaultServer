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

    init(
        repository: UserLLMPreferenceRepository,
        routerProfiles: RouterProfileRepository,
        defaultPrimaryProvider: ProviderID = ManagedLLMDefaults.provider,
        defaultPrimaryModel: String = ManagedLLMDefaults.model,
        logger: Logger
    ) {
        self.repository = repository
        self.routerProfiles = routerProfiles
        self.defaultPrimaryProvider = defaultPrimaryProvider
        self.defaultPrimaryModel = defaultPrimaryModel
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: get)
        router.put(use: put)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> LLMPreferencesGetResponse {
        let tenantID = try ctx.requireTenantID()
        let snapshot = try await repository.get(tenantID: tenantID)
        return snapshot.flatMap(toWire) ?? LLMPreferencesGetResponse(
            mode: .managed,
            primaryProvider: defaultPrimaryProvider,
            primaryModel: ModelDisclosurePolicy.genericBrainName,
            fallbackChain: []
        )
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
        guard let response = toWire(snapshot) else {
            // Should be unreachable: PUT path goes through `toKind` which
            // round-trips a valid ProviderID. A nil here means the row's
            // primary provider isn't in the user-facing set, which only
            // happens if the schema is hand-edited.
            throw HTTPError(.internalServerError, message: "preference_unmappable")
        }
        return response
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
