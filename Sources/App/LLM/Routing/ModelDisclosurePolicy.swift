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
}
