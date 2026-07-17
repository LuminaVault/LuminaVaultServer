import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

actor RouterProfileRepository {
    private let fluent: Fluent
    private let legacyPreferences: UserLLMPreferenceRepository
    private let managedModel: String
    private let logger: Logger

    init(
        fluent: Fluent,
        legacyPreferences: UserLLMPreferenceRepository,
        managedModel: String,
        logger: Logger
    ) {
        self.fluent = fluent
        self.legacyPreferences = legacyPreferences
        self.managedModel = managedModel
        self.logger = logger
    }

    func list(tenantID: UUID) async throws -> RouterProfilesResponse {
        let defaultProfile = try await ensureDefault(tenantID: tenantID)
        let rows = try await RouterProfile.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .sort(\.$createdAt)
            .all()
        return try RouterProfilesResponse(
            profiles: rows.map(Self.toDTO),
            defaultProfileID: defaultProfile.requireID()
        )
    }

    func profile(tenantID: UUID, id: UUID) async throws -> RouterProfile? {
        try await RouterProfile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
    }

    func create(tenantID: UUID, request: RouterProfileWriteRequest) async throws -> RouterProfileDTO {
        let row = RouterProfile()
        row.id = UUID()
        row.tenantID = tenantID
        row.name = request.name
        row.mode = request.mode.rawValue
        row.isPreset = false
        row.document = Self.document(from: request)
        row.revision = 1
        try await row.create(on: fluent.db())
        return try Self.toDTO(row)
    }

    func update(tenantID: UUID, id: UUID, request: RouterProfileWriteRequest) async throws -> RouterProfileDTO? {
        guard let row = try await profile(tenantID: tenantID, id: id) else { return nil }
        if let expected = request.expectedRevision, expected != row.revision {
            throw RouterProfileRepositoryError.revisionConflict
        }
        row.name = request.name
        row.mode = request.mode.rawValue
        row.document = Self.document(from: request)
        row.revision += 1
        try await row.save(on: fluent.db())
        return try Self.toDTO(row)
    }

    func delete(tenantID: UUID, id: UUID) async throws -> Bool {
        let defaultProfile = try await ensureDefault(tenantID: tenantID)
        guard try defaultProfile.requireID() != id else {
            throw RouterProfileRepositoryError.cannotDeleteDefault
        }
        guard let row = try await profile(tenantID: tenantID, id: id) else { return false }
        try await row.delete(on: fluent.db())
        return true
    }

    func bindings(tenantID: UUID) async throws -> RouterBindingsResponse {
        _ = try await ensureDefault(tenantID: tenantID)
        let rows = try await RouterBinding.query(on: fluent.db(), tenantID: tenantID).all()
        return try RouterBindingsResponse(bindings: rows.map(Self.toDTO))
    }

    func bind(
        tenantID: UUID,
        scope: RouterBindingScope,
        scopeID: String,
        profileID: UUID
    ) async throws -> RouterBindingDTO {
        guard try await profile(tenantID: tenantID, id: profileID) != nil else {
            throw RouterProfileRepositoryError.profileNotFound
        }
        let existing = try await RouterBinding.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$scope == scope.rawValue)
            .filter(\.$scopeID == scopeID)
            .first()
        let row = existing ?? RouterBinding()
        if row.id == nil {
            row.id = UUID()
        }
        row.tenantID = tenantID
        row.scope = scope.rawValue
        row.scopeID = scopeID
        row.profileID = profileID
        try await row.save(on: fluent.db())
        return try Self.toDTO(row)
    }

    func unbind(tenantID: UUID, scope: RouterBindingScope, scopeID: String) async throws -> Bool {
        guard scope != .user else { throw RouterProfileRepositoryError.cannotDeleteDefault }
        guard let row = try await RouterBinding.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$scope == scope.rawValue)
            .filter(\.$scopeID == scopeID)
            .first()
        else { return false }
        try await row.delete(on: fluent.db())
        return true
    }

    func resolve(tenantID: UUID, spaceID: UUID?, jobID: String?) async throws -> RouterProfile {
        let candidates: [(RouterBindingScope, String?)] = [
            (.job, jobID),
            (.space, spaceID?.uuidString),
            (.user, tenantID.uuidString),
        ]
        for (scope, key) in candidates {
            guard let key else { continue }
            if let binding = try await RouterBinding.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$scope == scope.rawValue)
                .filter(\.$scopeID == key)
                .first(),
                let profile = try await profile(tenantID: tenantID, id: binding.profileID)
            {
                return profile
            }
        }
        return try await ensureDefault(tenantID: tenantID)
    }

    private func ensureDefault(tenantID: UUID) async throws -> RouterProfile {
        if let binding = try await RouterBinding.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$scope == RouterBindingScope.user.rawValue)
            .filter(\.$scopeID == tenantID.uuidString)
            .first(),
            let row = try await profile(tenantID: tenantID, id: binding.profileID)
        {
            return row
        }

        let legacy = try? await legacyPreferences.get(tenantID: tenantID)
        let primaryProvider = legacy?.primaryProvider.toShared() ?? .openRouter
        let primaryModel = legacy?.primaryModel.isEmpty == false ? legacy!.primaryModel : managedModel
        let fallbacks = legacy?.fallbackChain.compactMap { step -> RouterModelRouteDTO? in
            guard let provider = step.provider.toShared() else { return nil }
            return RouterModelRouteDTO(provider: provider, model: step.model)
        } ?? []
        let mode: LLMBrainMode = legacy?.mode == .byok ? .byok : .managed

        let row = RouterProfile()
        let profileID = UUID()
        row.id = profileID
        row.tenantID = tenantID
        row.name = "Default"
        row.mode = mode.rawValue
        row.isPreset = true
        // Multi-tier seed so Auto (Smart) has cheap → strong options from day one.
        // Preference primary stays first; catalog expands further at request time.
        var seedRoutes = [RouterModelRouteDTO(provider: primaryProvider, model: primaryModel)] + fallbacks
        let autoSeed: [RouterModelRouteDTO] = [
            RouterModelRouteDTO(provider: .gemini, model: "gemini-2.5-flash"),
            RouterModelRouteDTO(provider: .anthropic, model: "claude-3-5-haiku-20241022"),
            RouterModelRouteDTO(provider: .openai, model: "gpt-4o-mini"),
            RouterModelRouteDTO(provider: .openRouter, model: "deepseek/deepseek-chat"),
            RouterModelRouteDTO(provider: .anthropic, model: "claude-sonnet-4-6"),
            RouterModelRouteDTO(provider: .openai, model: "gpt-4o"),
            RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-1"),
        ]
        for route in autoSeed where !seedRoutes.contains(where: { $0.id == route.id }) {
            seedRoutes.append(route)
        }
        row.document = RouterProfileDocument(
            objective: .init(quality: 50, cost: 25, latency: 25),
            budget: .init(),
            allowedProviders: legacy?.allowedProviders.compactMap { $0.toShared() } ?? [],
            blockedProviders: legacy?.blockedProviders.compactMap { $0.toShared() } ?? [],
            defaultAction: RouterActionDTO(routes: seedRoutes),
            rules: [],
            routingPolicy: .autoSmart
        )
        row.revision = 1
        do {
            try await row.create(on: fluent.db())
            _ = try await bind(
                tenantID: tenantID,
                scope: .user,
                scopeID: tenantID.uuidString,
                profileID: profileID
            )
            return row
        } catch {
            logger.warning("cerberus default profile create raced; reloading", metadata: [
                "tenant_id": .string(tenantID.uuidString),
            ])
            if let binding = try await RouterBinding.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$scope == RouterBindingScope.user.rawValue)
                .filter(\.$scopeID == tenantID.uuidString)
                .first(),
                let winner = try await profile(tenantID: tenantID, id: binding.profileID)
            {
                return winner
            }
            throw error
        }
    }

    private static func document(from request: RouterProfileWriteRequest) -> RouterProfileDocument {
        RouterProfileDocument(
            objective: request.objective,
            budget: request.budget,
            allowedProviders: request.allowedProviders,
            blockedProviders: request.blockedProviders,
            defaultAction: request.defaultAction,
            rules: request.rules,
            routingPolicy: request.routingPolicy
        )
    }

    static func toDTO(_ row: RouterProfile) throws -> RouterProfileDTO {
        try RouterProfileDTO(
            id: row.requireID(),
            name: row.name,
            mode: LLMBrainMode(rawValue: row.mode) ?? .managed,
            isPreset: row.isPreset,
            objective: row.document.objective,
            budget: row.document.budget,
            allowedProviders: row.document.allowedProviders,
            blockedProviders: row.document.blockedProviders,
            defaultAction: row.document.defaultAction,
            rules: row.document.rules,
            routingPolicy: row.document.routingPolicy,
            revision: row.revision,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    private static func toDTO(_ row: RouterBinding) throws -> RouterBindingDTO {
        try RouterBindingDTO(
            id: row.requireID(),
            scope: RouterBindingScope(rawValue: row.scope) ?? .user,
            scopeID: row.scopeID,
            profileID: row.profileID
        )
    }
}

enum RouterProfileRepositoryError: Error {
    case revisionConflict
    case cannotDeleteDefault
    case profileNotFound
}
