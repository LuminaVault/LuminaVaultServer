import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared
import NIOCore

struct CerberusRequestScope: Hashable {
    let surface: RouterSurface
    let spaceID: UUID?
    let jobID: String?
    let workflowID: String?
    let conversationID: UUID?

    init(surface: RouterSurface, spaceID: UUID? = nil, jobID: String? = nil, workflowID: String? = nil, conversationID: UUID? = nil) {
        self.surface = surface
        self.spaceID = spaceID
        self.jobID = jobID
        self.workflowID = workflowID
        self.conversationID = conversationID
    }
}

struct CerberusDecisionMetadata: Hashable {
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
    let routingPolicy: LLMRoutingPolicy
    let complexity: RouterComplexity
    let reason: String
    /// BYOK mode with zero usable keys — transport must fail closed.
    let byokKeysRequired: Bool
    /// BYO Hermes owns routing; Auto was deferred.
    let deferredToHermes: Bool

    init(
        executionID: UUID,
        tenantID: UUID,
        vaultID: UUID,
        actorUserID: UUID,
        profileID: UUID,
        profileName: String,
        ruleID: UUID?,
        taskType: RouterTaskType,
        surface: RouterSurface,
        spaceID: UUID?,
        conversationID: UUID?,
        strategy: RouterActionKind,
        parallelStrategy: ParallelStrategyDTO?,
        participants: [ParallelParticipantDTO]?,
        routes: [RouterModelRouteDTO],
        synthesisRoute: RouterModelRouteDTO?,
        minimumSuccessfulResults: Int,
        retryPolicy: RouterRetryPolicy,
        predictedCostUsdMicros: Int64,
        budgetReservationUsdMicros: Int64,
        budgetDenied: Bool,
        mode: LLMBrainMode,
        routingPolicy: LLMRoutingPolicy = .autoSmart,
        complexity: RouterComplexity = .medium,
        reason: String = "",
        byokKeysRequired: Bool = false,
        deferredToHermes: Bool = false
    ) {
        self.executionID = executionID
        self.tenantID = tenantID
        self.vaultID = vaultID
        self.actorUserID = actorUserID
        self.profileID = profileID
        self.profileName = profileName
        self.ruleID = ruleID
        self.taskType = taskType
        self.surface = surface
        self.spaceID = spaceID
        self.conversationID = conversationID
        self.strategy = strategy
        self.parallelStrategy = parallelStrategy
        self.participants = participants
        self.routes = routes
        self.synthesisRoute = synthesisRoute
        self.minimumSuccessfulResults = minimumSuccessfulResults
        self.retryPolicy = retryPolicy
        self.predictedCostUsdMicros = predictedCostUsdMicros
        self.budgetReservationUsdMicros = budgetReservationUsdMicros
        self.budgetDenied = budgetDenied
        self.mode = mode
        self.routingPolicy = routingPolicy
        self.complexity = complexity
        self.reason = reason
        self.byokKeysRequired = byokKeysRequired
        self.deferredToHermes = deferredToHermes
    }
}

/// Thrown when BYOK is selected but the tenant has no usable provider keys.
struct BYOKKeysRequiredError: Error, Equatable, HTTPResponseError {
    let reasonCode = "byok_keys_required"
    let userMessage =
        "Add an LLM API key in Settings (OpenRouter recommended for Auto) or switch to Managed mode."

    var status: HTTPResponse.Status {
        .forbidden
    }

    var bodyData: Data {
        let envelope: [String: Any] = [
            "error": [
                "code": reasonCode,
                "message": userMessage,
                "cta": ["add_key", "switch_to_managed"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: bodyData))
        )
    }
}

enum CerberusStreamContext {
    @TaskLocal static var sink: (@Sendable (QueryStreamEvent) -> Void)?
}

enum RouterTaskClassifier {
    static func classify(_ prompt: String, surface: RouterSurface) -> RouterTaskType {
        if surface == .job || surface == .skill {
            return .automation
        }
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
    /// Optional credential store — enables BYOK-aware Auto pool expansion.
    let credentials: UserCredentialStore?
    let registry: ProviderRegistry?

    init(
        profiles: RouterProfileRepository,
        fallback: any ModelRouter,
        budget: RouterTelemetryService,
        ensemblesEnabled: Bool,
        logger: Logger,
        credentials: UserCredentialStore? = nil,
        registry: ProviderRegistry? = nil
    ) {
        self.profiles = profiles
        self.fallback = fallback
        self.budget = budget
        self.ensemblesEnabled = ensemblesEnabled
        self.logger = logger
        self.credentials = credentials
        self.registry = registry
    }

    func pick(forModel model: String?, capability: LLMCapabilityLevel, user: User?) async -> RouteDecision {
        let table = await fallback.pick(forModel: model, capability: capability, user: user)
        guard let user, let tenantID = try? user.requireID() else { return table }
        let scope = LLMRoutingContext.cerberusScope ?? CerberusRequestScope(surface: .system)
        let prompt = LLMRoutingContext.cerberusPrompt ?? ""

        // BYO Hermes owns model choice — Auto defers (product decision).
        if let resolution = LLMRoutingContext.currentResolution, resolution.isUserOverride {
            let task = RouterTaskClassifier.classify(prompt, surface: scope.surface)
            let complexity = ComplexityClassifier.classify(prompt, surface: scope.surface)
            let hermesPrimary = table.primary
            let selectedDTO = RouterModelRouteDTO(
                provider: hermesPrimary.provider.toShared() ?? .openRouter,
                model: hermesPrimary.modelID
            )
            let reason = AvailableModelPoolBuilder.reason(
                policy: .locked,
                complexity: complexity,
                task: task,
                selected: selectedDTO,
                deferred: true
            )
            let metadata = CerberusDecisionMetadata(
                executionID: UUID(),
                tenantID: tenantID,
                vaultID: LLMRoutingContext.analyticsVaultID ?? tenantID,
                actorUserID: tenantID,
                profileID: UUID(),
                profileName: "BYO Hermes",
                ruleID: nil,
                taskType: task,
                surface: scope.surface,
                spaceID: scope.spaceID,
                conversationID: scope.conversationID,
                strategy: .sequential,
                parallelStrategy: nil,
                participants: nil,
                routes: [selectedDTO],
                synthesisRoute: nil,
                minimumSuccessfulResults: 1,
                retryPolicy: .fast,
                predictedCostUsdMicros: 0,
                budgetReservationUsdMicros: 0,
                budgetDenied: false,
                mode: .byok,
                routingPolicy: .locked,
                complexity: complexity,
                reason: reason,
                deferredToHermes: true
            )
            return RouteDecision(primary: hermesPrimary, fallbacks: table.fallbacks, cerberus: metadata)
        }

        do {
            let row = try await profiles.resolve(
                tenantID: tenantID,
                spaceID: scope.spaceID,
                jobID: scope.jobID,
                workflowID: scope.workflowID
            )
            let profile = try RouterProfileRepository.toDTO(row)
            let policy = profile.routingPolicy
            let task = RouterTaskClassifier.classify(prompt, surface: scope.surface)
            let complexity = ComplexityClassifier.classify(prompt, surface: scope.surface)
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
                    if !routes.contains(where: { $0.id == route.id }) {
                        routes.append(route)
                    }
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
            if action.kind == .ensemble, !ensemblesEnabled || effectiveTier != .ultimate {
                action = profile.defaultAction.kind == .sequential
                    ? profile.defaultAction
                    : RouterActionDTO(kind: .sequential, routes: action.routes, retryPolicy: action.retryPolicy)
            }

            // Credentialed providers for BYOK-aware pool.
            let credentialed = await credentialedProviderIDs(tenantID: tenantID)
            let deploymentEnabled = await deploymentEnabledProviderIDs()

            // BYOK + zero keys -> fail closed (confirmed product law).
            if profile.mode == .byok, credentialed.isEmpty {
                return Self.byokKeysRequiredDecision(
                    table: table,
                    tenantID: tenantID,
                    profile: profile,
                    ruleID: rule?.id,
                    task: task,
                    scope: scope,
                    policy: policy,
                    complexity: complexity,
                    reason: "Add an API key (OpenRouter recommended) or switch to Managed"
                )
            }

            let minTier: RouterModelTier = switch policy {
            case .locked:
                .fast // not applied — locked uses profile routes only
            case .fastCheap:
                .fast
            case .balanced:
                RouterModelTier.minimum(for: complexity)
            case .maxQuality:
                // Still allow cheap on trivial turns if confidence is high.
                complexity == .low ? .fast : .max
            case .autoSmart:
                RouterModelTier.minimum(for: complexity)
            }

            let baseRoutes = action.routes.filter { route in
                !profile.blockedProviders.contains(route.provider)
                    && (profile.allowedProviders.isEmpty || profile.allowedProviders.contains(route.provider))
            }

            let filtered: [RouterModelRouteDTO] = if policy == .locked {
                baseRoutes
            } else {
                AvailableModelPoolBuilder.build(.init(
                    mode: profile.mode,
                    profileRoutes: baseRoutes,
                    allowedProviders: profile.allowedProviders,
                    blockedProviders: profile.blockedProviders,
                    credentialedProviders: credentialed,
                    deploymentEnabledProviders: deploymentEnabled,
                    minTier: minTier
                ))
            }

            guard !filtered.isEmpty else {
                if profile.mode == .byok {
                    return Self.byokKeysRequiredDecision(
                        table: table,
                        tenantID: tenantID,
                        profile: profile,
                        ruleID: rule?.id,
                        task: task,
                        scope: scope,
                        policy: policy,
                        complexity: complexity,
                        reason: "No BYOK providers are available for this router profile"
                    )
                }
                return table
            }

            let promptTokens = max(1, prompt.count / 4)
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
            let weights = policy.presetObjective ?? profile.objective
            let ordered = score(
                filtered,
                task: task,
                weights: weights,
                promptTokens: promptTokens,
                costFirst: costFirst
            )
            let mapped = ordered.compactMap(Self.toModelRoute)
            guard let primary = mapped.first, let selectedDTO = ordered.first else {
                await budget.release(tenantID: tenantID, reservedUsdMicros: predicted)
                if profile.mode == .byok {
                    return Self.byokKeysRequiredDecision(
                        table: table,
                        tenantID: tenantID,
                        profile: profile,
                        ruleID: rule?.id,
                        task: task,
                        scope: scope,
                        policy: policy,
                        complexity: complexity,
                        reason: "Choose a supported BYOK provider for this router profile"
                    )
                }
                return table
            }
            let reason = AvailableModelPoolBuilder.reason(
                policy: policy,
                complexity: complexity,
                task: task,
                selected: selectedDTO,
                deferred: false
            )
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
                mode: profile.mode,
                routingPolicy: policy,
                complexity: complexity,
                reason: reason
            )
            return RouteDecision(primary: primary, fallbacks: Array(mapped.dropFirst()), cerberus: metadata)
        } catch {
            logger.error("cerberus decision failed; using table router", metadata: ["error": .string("\(error)")])
            return table
        }
    }

    private static func byokKeysRequiredDecision(
        table: RouteDecision,
        tenantID: UUID,
        profile: RouterProfileDTO,
        ruleID: UUID?,
        task: RouterTaskType,
        scope: CerberusRequestScope,
        policy: LLMRoutingPolicy,
        complexity: RouterComplexity,
        reason: String
    ) -> RouteDecision {
        let metadata = CerberusDecisionMetadata(
            executionID: UUID(),
            tenantID: tenantID,
            vaultID: LLMRoutingContext.analyticsVaultID ?? tenantID,
            actorUserID: tenantID,
            profileID: profile.id,
            profileName: profile.name,
            ruleID: ruleID,
            taskType: task,
            surface: scope.surface,
            spaceID: scope.spaceID,
            conversationID: scope.conversationID,
            strategy: .sequential,
            parallelStrategy: nil,
            participants: nil,
            routes: [],
            synthesisRoute: nil,
            minimumSuccessfulResults: 1,
            retryPolicy: .fast,
            predictedCostUsdMicros: 0,
            budgetReservationUsdMicros: 0,
            budgetDenied: false,
            mode: .byok,
            routingPolicy: policy,
            complexity: complexity,
            reason: reason,
            byokKeysRequired: true
        )
        // Primary is unused: RoutedLLMTransport checks byokKeysRequired before dispatch.
        return RouteDecision(primary: table.primary, fallbacks: [], cerberus: metadata)
    }

    private func credentialedProviderIDs(tenantID: UUID) async -> Set<ProviderID> {
        guard let credentials else { return [] }
        var result = Set<ProviderID>()
        for kind in ProviderKind.userCredentialTargets {
            guard let shared = kind.toShared() else { continue }
            if let cred = try? await credentials.credential(for: kind, tenantID: tenantID),
               cred.apiKey != nil || cred.baseURL != nil
            {
                result.insert(shared)
            }
        }
        return result
    }

    private func deploymentEnabledProviderIDs() async -> Set<ProviderID> {
        guard let registry else {
            // Managed path always has Hermes as last resort.
            return []
        }
        var result = Set<ProviderID>()
        for kind in ProviderKind.allCases {
            guard await registry.isEnabled(kind), let shared = kind.toShared() else { continue }
            result.insert(shared)
        }
        return result
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
        let latency = Double(catalog?.defaultLatencyMs ?? 2000)
        let latencyScore = 1 / (1 + latency / 1000)
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
            let outputCost = Int64(1024) * outputRate / 1_000_000
            return partial + inputCost + outputCost
        }
        let synthesisCost: Int64 = synthesis.map { route in
            let catalog = RouterModelCatalog.entry(provider: route.provider, model: route.model)
            let inputRate = route.inputPerMillionUsdMicros ?? catalog?.inputPerMillionUsdMicros ?? 0
            let outputRate = route.outputPerMillionUsdMicros ?? catalog?.outputPerMillionUsdMicros ?? 0
            let inputTokens = Int64(promptTokens * max(2, routes.count))
            let inputCost = inputTokens * inputRate / 1_000_000
            let outputCost = Int64(1024) * outputRate / 1_000_000
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
