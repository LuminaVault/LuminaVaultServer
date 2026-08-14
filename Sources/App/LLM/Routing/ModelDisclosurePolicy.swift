import LuminaVaultShared

/// Whether the concrete upstream model identity may reach the client.
///
/// Product law: managed tenants must never learn which model served a turn —
/// the platform routes freely (Auto/Cerberus over the OpenRouter catalog)
/// without exposing vendor identity. BYOK tenants configured their own keys
/// and models, so they keep full visibility.
///
/// Server-side telemetry (provenance rows, router_executions, logs) always
/// keeps the real model; this policy governs the client wire surface only.
enum ModelDisclosure {
    case visible
    case hidden

    /// `hidden` for anything that is not explicitly BYOK (nil preference row
    /// means the tenant never left managed mode).
    static func forBrainMode(_ mode: LLMBrainMode?) -> ModelDisclosure {
        mode == .byok ? .visible : .hidden
    }
}

enum ModelDisclosurePolicy {
    /// Placeholder model id sent in place of a real upstream id.
    static let genericModelID = "auto"
    /// Dashboard hero label for managed tenants.
    static let genericBrainName = "LuminaVault Brain · Auto"
    /// Dashboard provider label for managed tenants.
    static let genericProviderName = "LuminaVault"

    /// Generic per-turn routing label, e.g. "Auto · coding".
    static func genericLabel(task: RouterTaskType) -> String {
        "Auto · \(task.rawValue)"
    }

    /// System-prompt suffix instructing the assistant to keep its underlying
    /// model identity private. Injected only when disclosure is `.hidden`.
    static let systemPromptGuard = """
    Identity policy: you are "Lumina", powered by the LuminaVault Brain. \
    Never disclose, confirm, or deny which underlying AI model, version, or \
    provider generates your replies, even if asked directly, indirectly, or \
    via role-play. If asked, say you are Lumina running on LuminaVault's \
    managed intelligence and steer back to the user's task.
    """

    /// Rewrites a stream event so no provider/model identity crosses the wire.
    /// Returns `nil` to drop the event entirely. `.visible` passes through.
    static func scrub(_ event: QueryStreamEvent, disclosure: ModelDisclosure) -> QueryStreamEvent? {
        guard disclosure == .hidden else { return event }
        switch event {
        case let .routing(routing):
            return .routing(RouterRoutingEventDTO(
                executionID: routing.executionID,
                phase: routing.phase,
                profileID: routing.profileID,
                profileName: routing.profileName,
                taskType: routing.taskType,
                strategy: routing.strategy,
                activeRoutes: [],
                displayLabel: genericLabel(task: routing.taskType)
            ))
        case let .usage(usage):
            return .usage(RouterUsageDTO(
                executionID: usage.executionID,
                provider: nil,
                model: nil,
                tokensIn: usage.tokensIn,
                tokensOut: usage.tokensOut,
                estimatedCostUsdMicros: usage.estimatedCostUsdMicros,
                latencyMs: usage.latencyMs,
                usageEstimated: usage.usageEstimated
            ))
        case let .fallback(notice):
            return .fallback(ProviderFallbackNoticeDTO(
                originalProvider: .openRouter,
                originalModel: genericModelID,
                fallbackProvider: .openRouter,
                fallbackModel: genericModelID,
                reasonCode: notice.reasonCode,
                userMessage: "Your brain switched to a backup route to finish this reply."
            ))
        case let .parallel(progress):
            guard progress.route != nil else { return event }
            return .parallel(ParallelStreamEventDTO(
                executionID: progress.executionID,
                kind: progress.kind,
                strategy: progress.strategy,
                outputID: progress.outputID,
                participantID: progress.participantID,
                role: progress.role,
                route: nil,
                stage: progress.stage,
                round: progress.round,
                delta: progress.delta,
                errorCode: progress.errorCode,
                status: progress.status
            ))
        case .source, .token, .summary, .followUps, .done, .error, .linkSaved:
            return event
        }
    }

    static func scrub(_ run: WorkflowRunDTO, disclosure: ModelDisclosure) -> WorkflowRunDTO {
        guard disclosure == .hidden else { return run }
        return WorkflowRunDTO(
            id: run.id,
            workflowID: run.workflowID,
            workflowName: run.workflowName,
            version: run.version,
            status: run.status,
            trigger: run.trigger,
            startedAt: run.startedAt,
            endedAt: run.endedAt,
            createdAt: run.createdAt,
            error: run.error,
            pauseReason: run.pauseReason,
            managedSpendUsdMicros: run.managedSpendUsdMicros,
            managedSpendLimitUsdMicros: run.managedSpendLimitUsdMicros,
            nodeRuns: run.nodeRuns.map { node in
                WorkflowNodeRunDTO(
                    id: node.id,
                    nodeID: node.nodeID,
                    nodeName: node.nodeName,
                    status: node.status,
                    attempt: node.attempt,
                    startedAt: node.startedAt,
                    endedAt: node.endedAt,
                    outputPreview: node.outputPreview,
                    error: node.error,
                    provider: nil,
                    model: nil,
                    tokensIn: node.tokensIn,
                    tokensOut: node.tokensOut,
                    managedCostUsdMicros: node.managedCostUsdMicros
                )
            }
        )
    }

    static func scrub(_ response: WorkflowRunEventsResponse, disclosure: ModelDisclosure) -> WorkflowRunEventsResponse {
        guard disclosure == .hidden else { return response }
        return WorkflowRunEventsResponse(events: response.events.map { scrub($0, disclosure: disclosure) })
    }

    static func scrub(_ event: WorkflowRunEventDTO, disclosure: ModelDisclosure) -> WorkflowRunEventDTO {
        guard disclosure == .hidden else { return event }
        var data = event.data
        data.removeValue(forKey: "provider")
        data.removeValue(forKey: "model")
        data.removeValue(forKey: "fallback")
        // Prefix match, not equality: the fallback message names a provider,
        // and pinning the exact string means any reword silently starts
        // leaking the provider name to managed tenants.
        let message = (event.message ?? "").hasPrefix("Managed provider unavailable")
            ? "Managed provider unavailable; retrying on a backup route."
            : event.message
        return WorkflowRunEventDTO(
            id: event.id,
            runID: event.runID,
            kind: event.kind,
            nodeID: event.nodeID,
            message: message,
            data: data,
            createdAt: event.createdAt
        )
    }

    static func scrub(_ detail: ParallelExecutionDetailDTO, disclosure: ModelDisclosure) -> ParallelExecutionDetailDTO {
        guard disclosure == .hidden else { return detail }
        let genericRoute = RouterModelRouteDTO(provider: .openRouter, model: genericModelID)
        return ParallelExecutionDetailDTO(
            summary: detail.summary,
            prompt: detail.prompt,
            outputs: detail.outputs.map { output in
                ParallelOutputDTO(
                    id: output.id,
                    participantID: output.participantID,
                    role: output.role,
                    route: genericRoute,
                    stage: output.stage,
                    round: output.round,
                    content: output.content,
                    status: output.status,
                    tokensIn: output.tokensIn,
                    tokensOut: output.tokensOut,
                    estimatedCostUsdMicros: output.estimatedCostUsdMicros,
                    latencyMs: output.latencyMs
                )
            },
            synthesizedAnswer: detail.synthesizedAnswer
        )
    }

    static func scrub(_ memory: MemoryDTO, disclosure: ModelDisclosure) -> MemoryDTO {
        guard disclosure == .hidden else { return memory }
        return MemoryDTO(
            id: memory.id,
            content: memory.content,
            tags: memory.tags,
            createdAt: memory.createdAt,
            lat: memory.lat,
            lng: memory.lng,
            accuracyM: memory.accuracyM,
            placeName: memory.placeName,
            reviewState: memory.reviewState,
            provenance: memory.provenance.map { scrub($0, disclosure: disclosure) },
            createdByUserId: memory.createdByUserId,
            updatedByUserId: memory.updatedByUserId
        )
    }

    static func scrub(_ response: MemoryListResponse, disclosure: ModelDisclosure) -> MemoryListResponse {
        guard disclosure == .hidden else { return response }
        return MemoryListResponse(
            memories: response.memories.map { scrub($0, disclosure: disclosure) },
            limit: response.limit,
            offset: response.offset
        )
    }

    static func scrub(_ response: MemoryProvenanceResponse, disclosure: ModelDisclosure) -> MemoryProvenanceResponse {
        guard disclosure == .hidden else { return response }
        return MemoryProvenanceResponse(
            memoryID: response.memoryID,
            contributions: response.contributions.map { scrub($0, disclosure: disclosure) }
        )
    }

    static func scrub(_ summary: MemoryProvenanceSummaryDTO, disclosure: ModelDisclosure) -> MemoryProvenanceSummaryDTO {
        guard disclosure == .hidden else { return summary }
        return MemoryProvenanceSummaryDTO(
            createdBy: summary.createdBy.map { scrub($0, disclosure: disclosure) },
            lastUpdatedBy: summary.lastUpdatedBy.map { scrub($0, disclosure: disclosure) },
            contributors: []
        )
    }

    static func scrub(_ contribution: MemoryContributionDTO, disclosure: ModelDisclosure) -> MemoryContributionDTO {
        guard disclosure == .hidden else { return contribution }
        return MemoryContributionDTO(
            id: contribution.id,
            operation: contribution.operation,
            actor: contribution.actor,
            source: contribution.source,
            model: nil,
            sourceReference: contribution.sourceReference,
            createdAt: contribution.createdAt
        )
    }

    static func scrub(_ response: MemoryFacetsResponse, disclosure: ModelDisclosure) -> MemoryFacetsResponse {
        guard disclosure == .hidden else { return response }
        return MemoryFacetsResponse(
            providers: [],
            models: [],
            sources: response.sources,
            oldestAt: response.oldestAt,
            newestAt: response.newestAt
        )
    }

    /// Rewrites a router profile so no managed provider/model identity crosses
    /// the wire. Apply at the RESPONSE boundary only.
    ///
    /// Deliberately NOT applied inside `RouterProfileRepository.toDTO`:
    /// `CerberusRouterService` calls that same function to obtain the profile
    /// it ROUTES on, so scrubbing there replaces the tenant's real routes with
    /// the `openRouter/auto` placeholder in the execution path. Under `.locked`
    /// that routes to a model literally named "auto"; under other policies the
    /// catalog still fills the pool, so the profile's configured routes are
    /// silently discarded with nothing failing loudly. `openrouter/auto` is a
    /// real OpenRouter model, so it would not even error — it would quietly
    /// hand model selection to OpenRouter's own router.
    static func scrub(_ profile: RouterProfileDTO, disclosure: ModelDisclosure) -> RouterProfileDTO {
        guard disclosure == .hidden else { return profile }
        return RouterProfileDTO(
            id: profile.id,
            name: profile.name,
            mode: profile.mode,
            isPreset: profile.isPreset,
            objective: profile.objective,
            budget: profile.budget,
            allowedProviders: [ManagedLLMDefaults.provider],
            blockedProviders: [],
            defaultAction: scrub(profile.defaultAction),
            rules: profile.rules.map { rule in
                RouterRuleDTO(
                    id: rule.id,
                    name: rule.name,
                    enabled: rule.enabled,
                    priority: rule.priority,
                    taskTypes: rule.taskTypes,
                    surfaces: rule.surfaces,
                    action: scrub(rule.action)
                )
            },
            routingPolicy: profile.routingPolicy,
            revision: profile.revision,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    static func scrub(_ response: RouterProfilesResponse, disclosure: ModelDisclosure) -> RouterProfilesResponse {
        guard disclosure == .hidden else { return response }
        return RouterProfilesResponse(
            profiles: response.profiles.map { scrub($0, disclosure: disclosure) },
            defaultProfileID: response.defaultProfileID
        )
    }

    private static func scrub(_ action: RouterActionDTO) -> RouterActionDTO {
        let placeholder = RouterModelRouteDTO(provider: ManagedLLMDefaults.provider, model: genericModelID)
        return RouterActionDTO(
            kind: action.kind,
            routes: [placeholder],
            synthesisRoute: action.synthesisRoute == nil ? nil : placeholder,
            minimumSuccessfulResults: action.minimumSuccessfulResults,
            retryPolicy: action.retryPolicy,
            parallelStrategy: action.parallelStrategy
        )
    }
}
