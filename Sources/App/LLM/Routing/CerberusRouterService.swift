import Foundation
import Logging
import LuminaVaultShared

struct CerberusRequestScope: Sendable, Hashable {
    let surface: RouterSurface
    let spaceID: UUID?
    let jobID: String?
    let conversationID: UUID?

    init(surface: RouterSurface, spaceID: UUID? = nil, jobID: String? = nil, conversationID: UUID? = nil) {
        self.surface = surface
        self.spaceID = spaceID
        self.jobID = jobID
        self.conversationID = conversationID
    }
}

struct CerberusDecisionMetadata: Hashable, Sendable {
    let executionID: UUID
    let tenantID: UUID
    let vaultID: UUID
    let actorUserID: UUID
    let profileID: UUID
    let profileName: String
    let ruleID: UUID?
    let taskType: RouterTaskType
    let surface: RouterSurface
    let spaceID: UUID?
    let conversationID: UUID?
    let strategy: RouterActionKind
    let parallelStrategy: ParallelStrategyDTO?
    let participants: [ParallelParticipantDTO]?
    let routes: [RouterModelRouteDTO]
    let synthesisRoute: RouterModelRouteDTO?
    let minimumSuccessfulResults: Int
    let retryPolicy: RouterRetryPolicy
    let predictedCostUsdMicros: Int64
    let budgetReservationUsdMicros: Int64
    let budgetDenied: Bool
    let mode: LLMBrainMode
}

enum CerberusStreamContext {
    @TaskLocal static var sink: (@Sendable (QueryStreamEvent) -> Void)?
}

enum RouterTaskClassifier {
    static func classify(_ prompt: String, surface: RouterSurface) -> RouterTaskType {
        if surface == .job || surface == .skill { return .automation }
        let value = prompt.lowercased()
        if containsAny(value, ["search", "latest", "today", "news", "find online", "look up", "research"]) {
            return .search
        }
        if containsAny(value, ["code", "swift", "typescript", "python", "sql", "debug", "compile", "api", "function"]) {
            return .coding
        }
        if containsAny(value, ["summarize", "summary", "tl;dr", "condense", "key points"]) {
            return .summarization
        }
        if containsAny(value, ["extract", "parse", "fields", "entities", "json from"]) {
            return .extraction
        }
        if containsAny(value, ["write a story", "poem", "brainstorm", "creative", "tagline", "imagine"]) {
            return .creative
        }
        if containsAny(value, ["reason", "analyze", "compare", "trade-off", "prove", "why", "plan"]) {
            return .reasoning
        }
        return .general
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

/// Profile-aware model router. Existing table routing remains its safety net,
/// so profile lookup or validation failures never leave chat without a route.
struct CerberusModelRouter: ModelRouter {
    let profiles: RouterProfileRepository
    let fallback: any ModelRouter
    let budget: RouterTelemetryService
    let ensemblesEnabled: Bool
    let logger: Logger

    func pick(forModel model: String?, capability: LLMCapabilityLevel, user: User?) async -> RouteDecision {
        let table = await fallback.pick(forModel: model, capability: capability, user: user)
        guard let user, let tenantID = try? user.requireID() else { return table }
        let scope = LLMRoutingContext.cerberusScope ?? CerberusRequestScope(surface: .system)
        do {
            let row = try await profiles.resolve(tenantID: tenantID, spaceID: scope.spaceID, jobID: scope.jobID)
            let profile = try RouterProfileRepository.toDTO(row)
            let task = RouterTaskClassifier.classify(LLMRoutingContext.cerberusPrompt ?? "", surface: scope.surface)
            let rule = profile.rules
                .filter { rule in
                    rule.enabled
                        && (rule.taskTypes.isEmpty || rule.taskTypes.contains(task))
                        && (rule.surfaces.isEmpty || rule.surfaces.contains(scope.surface))
                }
                .sorted { $0.priority < $1.priority }
                .first
            var action = rule?.action ?? profile.defaultAction
            let effectiveTier = EntitlementChecker.effectiveTier(
                tier: user.tierEnum,
                override: user.tierOverrideEnum
            )
            let parallelRequest = LLMRoutingContext.parallelRequest
            let requestedParallelStrategy = parallelRequest?.strategy ?? LLMRoutingContext.parallelStrategy
            if requestedParallelStrategy != nil, ensemblesEnabled, effectiveTier == .ultimate {
                var routes = parallelRequest?.participants?.map(\.route) ?? action.routes
                for candidate in table.candidates {
                    guard let provider = candidate.provider.toShared() else { continue }
                    let route = RouterModelRouteDTO(provider: provider, model: candidate.modelID)
                    if !routes.contains(where: { $0.id == route.id }) { routes.append(route) }
                }
                routes = Array(routes.prefix(3))
                if routes.count >= 2 {
                    action = RouterActionDTO(
                        kind: .ensemble,
                        routes: routes,
                        synthesisRoute: parallelRequest?.synthesisRoute ?? action.synthesisRoute ?? routes.first,
                        minimumSuccessfulResults: requestedParallelStrategy == .bestOfN ? 1 : 2,
                        retryPolicy: action.retryPolicy
                    )
                }
            }
            if action.kind == .ensemble, (!ensemblesEnabled || effectiveTier != .ultimate) {
                action = profile.defaultAction.kind == .sequential
                    ? profile.defaultAction
                    : RouterActionDTO(kind: .sequential, routes: action.routes, retryPolicy: action.retryPolicy)
            }
            let filtered = action.routes.filter { route in
                !profile.blockedProviders.contains(route.provider)
                    && (profile.allowedProviders.isEmpty || profile.allowedProviders.contains(route.provider))
            }
            guard !filtered.isEmpty else { return table }

            let promptTokens = max(1, (LLMRoutingContext.cerberusPrompt?.count ?? 0) / 4)
            let effectiveParallelStrategy = requestedParallelStrategy ?? action.parallelStrategy
            let predicted = predictedCost(
                routes: filtered,
                synthesis: action.synthesisRoute,
                promptTokens: promptTokens,
                workerRounds: effectiveParallelStrategy == .debate ? 2 : 1
            )
            let budgetState = await budget.reserve(
                tenantID: tenantID,
                predictedUsdMicros: predicted,
                policy: profile.budget
            )
            let costFirst = budgetState == .softLimit
            let ordered = score(
                filtered,
                task: task,
                weights: profile.objective,
                promptTokens: promptTokens,
                costFirst: costFirst
            )
            let mapped = ordered.compactMap(Self.toModelRoute)
            guard let primary = mapped.first else {
                await budget.release(tenantID: tenantID, reservedUsdMicros: predicted)
                return table
            }
            let metadata = CerberusDecisionMetadata(
                executionID: UUID(),
                tenantID: tenantID,
                vaultID: LLMRoutingContext.analyticsVaultID ?? tenantID,
                actorUserID: tenantID,
                profileID: profile.id,
                profileName: profile.name,
                ruleID: rule?.id,
                taskType: task,
                surface: scope.surface,
                spaceID: scope.spaceID,
                conversationID: scope.conversationID,
                strategy: action.kind,
                parallelStrategy: action.kind == .ensemble
                    ? (requestedParallelStrategy ?? action.parallelStrategy ?? .consensus)
                    : nil,
                participants: parallelRequest?.participants ?? action.participants,
                routes: ordered,
                synthesisRoute: action.synthesisRoute,
                minimumSuccessfulResults: action.minimumSuccessfulResults ?? 2,
                retryPolicy: action.retryPolicy,
                predictedCostUsdMicros: predicted,
                budgetReservationUsdMicros: budgetState == .denied ? 0 : predicted,
                budgetDenied: budgetState == .denied,
                mode: profile.mode
            )
            return RouteDecision(primary: primary, fallbacks: Array(mapped.dropFirst()), cerberus: metadata)
        } catch {
            logger.error("cerberus decision failed; using table router", metadata: ["error": .string("\(error)")])
            return table
        }
    }

    private func score(
        _ routes: [RouterModelRouteDTO],
        task: RouterTaskType,
        weights: RouterObjectiveWeightsDTO,
        promptTokens: Int,
        costFirst: Bool
    ) -> [RouterModelRouteDTO] {
        let effective = costFirst ? RouterObjectiveWeightsDTO(quality: 10, cost: 80, latency: 10) : weights
        return routes.enumerated().sorted { lhs, rhs in
            let left = score(lhs.element, task: task, weights: effective, promptTokens: promptTokens)
            let right = score(rhs.element, task: task, weights: effective, promptTokens: promptTokens)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    private func score(
        _ route: RouterModelRouteDTO,
        task: RouterTaskType,
        weights: RouterObjectiveWeightsDTO,
        promptTokens: Int
    ) -> Double {
        let catalog = RouterModelCatalog.entry(provider: route.provider, model: route.model)
        let quality = Double(catalog?.taskQuality[task.rawValue] ?? 50) / 100
        let latency = Double(catalog?.defaultLatencyMs ?? 2_000)
        let latencyScore = 1 / (1 + latency / 1_000)
        let cost = Double(predictedCost(routes: [route], synthesis: nil, promptTokens: promptTokens))
        let costScore = 1 / (1 + cost / 1_000_000)
        return quality * Double(weights.quality)
            + costScore * Double(weights.cost)
            + latencyScore * Double(weights.latency)
    }

    private func predictedCost(
        routes: [RouterModelRouteDTO],
        synthesis: RouterModelRouteDTO?,
        promptTokens: Int,
        workerRounds: Int = 1
    ) -> Int64 {
        let workers = routes.reduce(Int64(0)) { partial, route in
            let catalog = RouterModelCatalog.entry(provider: route.provider, model: route.model)
            let inputRate = route.inputPerMillionUsdMicros ?? catalog?.inputPerMillionUsdMicros ?? 0
            let outputRate = route.outputPerMillionUsdMicros ?? catalog?.outputPerMillionUsdMicros ?? 0
            let inputCost = Int64(promptTokens) * inputRate / 1_000_000
            let outputCost = Int64(1_024) * outputRate / 1_000_000
            return partial + inputCost + outputCost
        }
        let synthesisCost: Int64 = synthesis.map { route in
            let catalog = RouterModelCatalog.entry(provider: route.provider, model: route.model)
            let inputRate = route.inputPerMillionUsdMicros ?? catalog?.inputPerMillionUsdMicros ?? 0
            let outputRate = route.outputPerMillionUsdMicros ?? catalog?.outputPerMillionUsdMicros ?? 0
            let inputTokens = Int64(promptTokens * max(2, routes.count))
            let inputCost = inputTokens * inputRate / 1_000_000
            let outputCost = Int64(1_024) * outputRate / 1_000_000
            return inputCost + outputCost
        } ?? 0
        return workers * Int64(max(1, workerRounds)) + synthesisCost
    }

    private static func toModelRoute(_ route: RouterModelRouteDTO) -> ModelRoute? {
        guard let provider = ProviderKind(shared: route.provider) else { return nil }
        return ModelRoute(provider: provider, modelID: route.model)
    }
}

extension ProviderKind {
    init?(shared: ProviderID) {
        switch shared {
        case .xai: self = .xai
        case .nvidia: self = .nvidia
        case .anthropic: self = .anthropic
        case .openai: self = .openai
        case .ollama: self = .ollama
        case .openRouter: self = .openRouter
        case .gemini: self = .gemini
        case .nous: self = .nous
        case .custom: self = .custom
        }
    }
}
