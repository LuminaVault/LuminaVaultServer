import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension LLMPreferencesGetResponse: @retroactive ResponseEncodable {}

/// HER-252 — `/v1/me/preferences/llm` GET + PUT. Row absent ⇒ GET
/// returns a default response built from the deployment's static
/// `TableModelRouter` so iOS has something to render. PUT replaces the
/// whole row; no FK validation that the user actually owns credentials
/// for the chosen provider (the router skips providers without creds
/// at runtime, so misconfiguration is a UX problem, not a crash).
struct LLMPreferencesController {
    let repository: UserLLMPreferenceRepository
    let defaultPrimaryProvider: ProviderID
    let defaultPrimaryModel: String
    let logger: Logger

    init(
        repository: UserLLMPreferenceRepository,
        defaultPrimaryProvider: ProviderID = .openRouter,
        defaultPrimaryModel: String = "qwen/qwen-2.5-72b-instruct",
        logger: Logger
    ) {
        self.repository = repository
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
        return snapshot.flatMap(Self.toWire) ?? LLMPreferencesGetResponse(
            mode: .managed,
            primaryProvider: defaultPrimaryProvider,
            primaryModel: defaultPrimaryModel,
            fallbackChain: []
        )
    }

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> LLMPreferencesGetResponse {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: LLMPreferencesPutRequest.self, context: ctx)

        // Validate inputs. Empty primary model is rejected; empty
        // fallback chain is fine (means user wants strict single-provider
        // routing). Provider IDs are already validated by Codable.
        guard !body.primaryModel.isEmpty else {
            throw HTTPError(.badRequest, message: "primary_model_required")
        }
        for step in body.fallbackChain {
            if step.model.isEmpty {
                throw HTTPError(.badRequest, message: "fallback_model_required")
            }
        }

        let snapshot: UserLLMPreferenceRepository.Snapshot
        do {
            snapshot = try await repository.upsert(
                tenantID: tenantID,
                mode: Self.toModelMode(body.mode),
                primaryProvider: Self.toKind(body.primaryProvider),
                primaryModel: body.primaryModel,
                fallbackChain: body.fallbackChain.map {
                    UserLLMPreferenceRepository.Snapshot.Step(
                        provider: Self.toKind($0.provider),
                        model: $0.model
                    )
                },
                allowedProviders: body.allowedProviders.map(Self.toKind),
                blockedProviders: body.blockedProviders.map(Self.toKind)
            )
        } catch {
            logger.error("llm preference upsert failed: \(error)")
            throw HTTPError(.internalServerError, message: "preference_save_failed")
        }
        guard let response = Self.toWire(snapshot) else {
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

    private static func toWire(_ snapshot: UserLLMPreferenceRepository.Snapshot) -> LLMPreferencesGetResponse? {
        guard let primary = snapshot.primaryProvider.toShared() else {
            return nil
        }
        let chain = snapshot.fallbackChain.compactMap { step -> ModelRouteDTO? in
            guard let id = step.provider.toShared() else { return nil }
            return ModelRouteDTO(provider: id, model: step.model)
        }
        return LLMPreferencesGetResponse(
            mode: toWireMode(snapshot.mode),
            primaryProvider: primary,
            primaryModel: snapshot.primaryModel,
            fallbackChain: chain,
            allowedProviders: snapshot.allowedProviders.compactMap { $0.toShared() },
            blockedProviders: snapshot.blockedProviders.compactMap { $0.toShared() }
        )
    }
}
