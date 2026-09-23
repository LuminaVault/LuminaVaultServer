import LuminaVaultShared

extension ModelDisclosurePolicy {
    /// The route `/v1/router` shows in place of a managed profile's real ones.
    ///
    /// It is a mask, not a model: no provider serves `auto` under that id, so
    /// it must never be stored as a route someone will be charged for.
    static func isPlaceholder(_ route: RouterModelRouteDTO) -> Bool {
        route.provider == ManagedLLMDefaults.provider && route.model == genericModelID
    }
}

/// What a BYOK router save does with the placeholder a client carried back.
///
/// A client that fetches a managed profile, flips it to BYOK and saves it
/// sends back the placeholder it was shown. The placeholder is replaced by the
/// tenant's own saved BYOK chain — the models they already told us they want —
/// and when there is no such chain the save is refused rather than stored with
/// a route that cannot run. The managed default is never substituted: that
/// would reveal the model it hides and spend on it from a BYOK profile.
enum RouterPlaceholderRoutes {
    static func substitute(
        in request: RouterProfileWriteRequest,
        chain: [RouterModelRouteDTO]
    ) throws -> RouterProfileWriteRequest {
        // A managed save is rewritten wholesale by `managedDocument`.
        guard request.mode == .byok else { return request }
        let actions = [request.defaultAction] + request.rules.map(\.action)
        guard actions.contains(where: carriesPlaceholder) else { return request }
        guard let primary = chain.first else { throw RouterProfileRepositoryError.placeholderRoute }

        func resolve(_ action: RouterActionDTO) -> RouterActionDTO {
            guard carriesPlaceholder(action) else { return action }
            var seen = Set<String>()
            let routes = action.routes
                .flatMap { isPlaceholder($0) ? chain : [$0] }
                .filter { seen.insert($0.id).inserted }
            // Synthesis is one model, so it takes the chain's primary.
            let synthesis = action.synthesisRoute.map { isPlaceholder($0) ? primary : $0 }
            return RouterActionDTO(
                kind: action.kind,
                routes: routes,
                synthesisRoute: synthesis,
                minimumSuccessfulResults: action.minimumSuccessfulResults,
                retryPolicy: action.retryPolicy,
                parallelStrategy: action.parallelStrategy,
                participants: action.participants
            )
        }

        return RouterProfileWriteRequest(
            name: request.name,
            mode: request.mode,
            objective: request.objective,
            budget: request.budget,
            allowedProviders: request.allowedProviders,
            blockedProviders: request.blockedProviders,
            defaultAction: resolve(request.defaultAction),
            rules: request.rules.map { rule in
                RouterRuleDTO(
                    id: rule.id,
                    name: rule.name,
                    enabled: rule.enabled,
                    priority: rule.priority,
                    taskTypes: rule.taskTypes,
                    surfaces: rule.surfaces,
                    action: resolve(rule.action)
                )
            },
            routingPolicy: request.routingPolicy,
            expectedRevision: request.expectedRevision
        )
    }

    private static func isPlaceholder(_ route: RouterModelRouteDTO) -> Bool {
        ModelDisclosurePolicy.isPlaceholder(route)
    }

    private static func carriesPlaceholder(_ action: RouterActionDTO) -> Bool {
        action.routes.contains(where: isPlaceholder) || action.synthesisRoute.map(isPlaceholder) == true
    }
}
