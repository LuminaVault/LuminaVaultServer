import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import NIOCore

/// Routes the user-facing chat **stream** by mode:
///
/// - **managed** → delegate to `fallback` (the central Hermes gateway,
///   `DefaultHermesLLMStreamService`). True token streaming + Hermes agentic
///   loop. Unchanged behaviour.
/// - **byok** → `RoutedLLMTransport.chatStream` (P2) — resolves the
///   tenant's own provider key + model, streams tokens natively per
///   provider (OpenAI-compat SSE, Anthropic Messages SSE, Gemini
///   `alt=sse`, Ollama NDJSON), and fails over across the fallback chain
///   until the first token arrives.
///
/// HER-37 left streaming on the gateway only, so the BYOK toggle changed only
/// the non-streaming paths and chat silently used the managed model
/// (qwen/openrouter) → 402 → empty turn. This closes that gap.
///
/// Requires `LLMRoutingContext.currentUser` to be bound by the caller so the
/// routed adapters can resolve the per-tenant credential — `ConversationController`
/// binds it around `chatStream(...)`, and the work `Task` created here captures
/// the task-local at creation time.
struct RoutedHermesLLMStreamService: HermesLLMStreamService {
    /// Managed-mode upstream (central Hermes gateway).
    let fallback: any HermesLLMStreamService
    /// BYOK transport — direct-to-provider with key resolution + failover.
    let transport: any HermesChatTransport
    let preferences: UserLLMPreferenceRepository
    let logger: Logger
    /// Cerberus router for managed-mode per-turn model selection. When set,
    /// the managed branch classifies the turn (task + complexity) and rides
    /// the gateway with the picked OpenRouter model instead of the fixed
    /// deployment default. `nil` preserves the legacy fixed-model behaviour.
    let router: (any ModelRouter)?
    /// Completes or releases Cerberus reservations made by `router.pick`.
    let routerTelemetry: RouterTelemetryService?

    init(
        fallback: any HermesLLMStreamService,
        transport: any HermesChatTransport,
        preferences: UserLLMPreferenceRepository,
        logger: Logger,
        router: (any ModelRouter)? = nil,
        routerTelemetry: RouterTelemetryService? = nil
    ) {
        self.fallback = fallback
        self.transport = transport
        self.preferences = preferences
        self.logger = logger
        self.router = router
        self.routerTelemetry = routerTelemetry
    }

    private let byokCounter = Counter(label: "luminavault.llm.chat.stream.byok")
    private let byokFailureCounter = Counter(label: "luminavault.llm.chat.stream.byok.failure")

    func chatStream(
        sessionKey: String,
        sessionID: String?,
        request: ChatRequest
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            do {
                if let strategy = LLMRoutingContext.parallelStrategy {
                    logger.info("chat stream routed to multi-model executor", metadata: ["strategy": .string(strategy.rawValue)])
                    let payload = try Self.makeOpenAIPayload(
                        model: request.model ?? "router-auto",
                        request: request
                    )
                    for try await chunk in transport.chatStream(
                        payload: payload,
                        sessionKey: sessionKey,
                        sessionID: sessionID
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } else if let model = await byokModel(sessionKey: sessionKey) {
                    byokCounter.increment()
                    logger.info("chat stream routed to BYOK provider", metadata: ["model": .string(model)])
                    let payload = try Self.makeOpenAIPayload(model: model, request: request)
                    // P2 — true per-token streaming. RoutedLLMTransport walks
                    // the user's fallback chain and only fails over before
                    // the first token; adapters without native streaming
                    // fall back to a single terminal chunk (old behaviour).
                    for try await chunk in transport.chatStream(
                        payload: payload,
                        sessionKey: sessionKey,
                        sessionID: sessionID
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } else {
                    // Managed: Cerberus picks the per-turn OpenRouter model;
                    // the gateway call itself is unchanged.
                    let managedRoute = try await managedAutoRequest(request)
                    let started = DispatchTime.now().uptimeNanoseconds
                    var outputCharacters = 0
                    do {
                        for try await chunk in fallback.chatStream(
                            sessionKey: sessionKey,
                            sessionID: sessionID,
                            request: managedRoute?.request ?? request
                        ) {
                            outputCharacters += chunk.delta.count
                            continuation.yield(chunk)
                        }
                        if Task.isCancelled {
                            await releaseManagedAutoReservation(managedRoute)
                            return
                        }
                        await completeManagedAutoRoute(
                            managedRoute,
                            outputCharacters: outputCharacters,
                            latencyMs: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                        )
                        continuation.finish()
                    } catch {
                        await releaseManagedAutoReservation(managedRoute)
                        throw error
                    }
                }
            } catch {
                byokFailureCounter.increment()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    // MARK: - Managed Auto (Smart) routing

    /// Runs Cerberus for a managed streaming turn. Returns a copy of `request`
    /// carrying the picked OpenRouter model id, or `nil` to keep the legacy
    /// deployment default (no router wired, Auto not active, BYO-Hermes
    /// deferral, or a non-OpenRouter pick the gateway cannot serve).
    private struct ManagedAutoRoute {
        let request: ChatRequest
        let metadata: CerberusDecisionMetadata
        let prompt: String
        let provider: ProviderKind
        let modelID: String
    }

    private func managedAutoRequest(_ request: ChatRequest) async throws -> ManagedAutoRoute? {
        guard let router else { return nil }
        let prompt = request.messages.last { $0.role == "user" }?.content ?? ""
        let decision = await LLMRoutingContext.$cerberusPrompt.withValue(prompt) {
            await router.pick(forModel: nil, capability: .high, user: LLMRoutingContext.currentUser)
        }
        guard let cerberus = decision.cerberus,
              // Gateway rides the platform's system key — never spend it for
              // a BYOK profile that merely fell through to this branch.
              cerberus.mode == .managed,
              cerberus.routingPolicy == .autoSmart,
              !cerberus.deferredToHermes,
              !cerberus.byokKeysRequired,
              // Managed Auto decisions are mapped onto the gateway route with
              // the picked OpenRouter model id (see CerberusModelRouter).
              decision.primary.provider == .hermesGateway || decision.primary.provider == .openRouter
        else { return nil }
        guard !cerberus.budgetDenied else { throw UsageCapExceededError(retryAfter: 3600) }

        logger.info("managed stream auto-routed", metadata: [
            "model": .string(decision.primary.modelID),
            "task": .string(cerberus.taskType.rawValue),
            "complexity": .string(cerberus.complexity.rawValue),
        ])
        // Surface the decision on the chat SSE sink — the controller scrubs
        // provider/model identity for managed tenants before it reaches the
        // wire — and record real provenance for server-side telemetry.
        CerberusStreamContext.sink?(.routing(RouterRoutingEventDTO(
            executionID: cerberus.executionID,
            phase: .selected,
            profileID: cerberus.profileID,
            profileName: cerberus.profileName,
            taskType: cerberus.taskType,
            strategy: cerberus.strategy,
            activeRoutes: cerberus.routes
        )))
        LLMRoutingContext.routeOutcomeSink?(ModelProvenanceDTO(
            provider: ProviderID.openRouter.rawValue,
            model: decision.primary.modelID,
            reason: cerberus.reason,
            routingPolicy: cerberus.routingPolicy,
            complexity: cerberus.complexity,
            taskType: cerberus.taskType
        ))
        return ManagedAutoRoute(
            request: ChatRequest(
                messages: request.messages,
                model: decision.primary.modelID,
                temperature: request.temperature,
                stream: request.stream,
                tools: request.tools,
                tool_choice: request.tool_choice,
                sessionID: request.sessionID
            ),
            metadata: cerberus,
            prompt: prompt,
            provider: .openRouter,
            modelID: decision.primary.modelID
        )
    }

    private func completeManagedAutoRoute(
        _ route: ManagedAutoRoute?,
        outputCharacters: Int,
        latencyMs: Int
    ) async {
        guard let route, let routerTelemetry else { return }
        let tokensIn = max(1, route.prompt.count / 4)
        let tokensOut = max(1, outputCharacters / 4)
        let cost = Self.estimatedCost(
            provider: route.provider,
            model: route.modelID,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            metadata: route.metadata
        )
        let result = RouterExecutionResult(
            provider: route.provider,
            model: route.modelID,
            status: "ok",
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            estimatedCostUsdMicros: cost,
            latencyMs: latencyMs,
            usageEstimated: true,
            fallbackCount: 0
        )
        await routerTelemetry.complete(metadata: route.metadata, result: result)
        publishUsage(route.metadata, result: result)
    }

    private func releaseManagedAutoReservation(_ route: ManagedAutoRoute?) async {
        guard let route, let routerTelemetry else { return }
        await routerTelemetry.release(
            tenantID: route.metadata.tenantID,
            reservedUsdMicros: route.metadata.budgetReservationUsdMicros
        )
    }

    // MARK: - Resolution

    /// Returns the tenant's BYOK primary model id when they are in BYOK mode,
    /// else nil (→ caller delegates to the managed gateway). The actual key +
    /// provider routing is resolved downstream by `RoutedLLMTransport` /
    /// `UserPreferenceModelRouter` via `LLMRoutingContext.currentUser`.
    private func byokModel(sessionKey: String) async -> String? {
        guard
            let tenantID = UUID(uuidString: sessionKey),
            let pref = try? await preferences.get(tenantID: tenantID),
            pref.mode == .byok
        else { return nil }
        guard pref.primaryModel.isEmpty else { return pref.primaryModel }
        // A BYOK tenant with no model selected falls through to the managed
        // gateway — which means the turn runs on the PLATFORM's system key
        // while the user believes they are on their own. That is silent
        // mis-billing, and it was previously invisible.
        //
        // Kept as a fallback rather than a hard failure so nobody's chat breaks
        // mid-session, but it is now loud. Whether this should fail closed (and
        // force the user to pick a model) is a product call, not a code one.
        logger.warning("byok tenant has no primary model — falling back to the MANAGED gateway key", metadata: [
            "tenant": .string(sessionKey),
            "billing": .string("managed_key_used_for_byok_tenant"),
        ])
        return nil
    }

    /// Encode an OpenAI-style chat payload from a `ChatRequest`, overriding the
    /// model with the tenant's BYOK selection.
    static func makeOpenAIPayload(model: String, request: ChatRequest) throws -> Data {
        struct Payload: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double?
        }
        return try JSONEncoder().encode(
            Payload(model: model, messages: request.messages, temperature: request.temperature)
        )
    }

    /// Pull `choices[0].message.content` out of an OpenAI chat-completions
    /// response. Empty string when absent (caller's empty-completion policy
    /// then surfaces it as an error event rather than a blank turn).
    static func extractContent(from data: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return "" }
        return content
    }

    private func publishUsage(_ metadata: CerberusDecisionMetadata, result: RouterExecutionResult) {
        CerberusStreamContext.sink?(.usage(RouterUsageDTO(
            executionID: metadata.executionID,
            provider: result.provider?.toShared(),
            model: result.model,
            tokensIn: result.tokensIn,
            tokensOut: result.tokensOut,
            estimatedCostUsdMicros: result.estimatedCostUsdMicros,
            latencyMs: result.latencyMs,
            usageEstimated: result.usageEstimated
        )))
    }

    private static func estimatedCost(
        provider: ProviderKind,
        model: String,
        tokensIn: Int,
        tokensOut: Int,
        metadata: CerberusDecisionMetadata
    ) -> Int64 {
        guard let shared = provider.toShared() else { return 0 }
        let route = metadata.routes.first { $0.provider == shared && $0.model == model }
        let catalog = RouterModelCatalog.entry(provider: shared, model: model)
        let inputRate = route?.inputPerMillionUsdMicros ?? catalog?.inputPerMillionUsdMicros ?? 0
        let outputRate = route?.outputPerMillionUsdMicros ?? catalog?.outputPerMillionUsdMicros ?? 0
        return Int64(tokensIn) * inputRate / 1_000_000 + Int64(tokensOut) * outputRate / 1_000_000
    }
}
