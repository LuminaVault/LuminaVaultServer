import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics

/// HER-165 — `HermesChatTransport` adapter that fans out to the routing
/// foundation. Asks `ModelRouter` for a decision, walks the candidates,
/// stops on first 2xx, fails over on `.transient` / `.network`, gives up
/// on `.permanent`.
///
/// HER-161 — the transport now takes an explicit `capability` so each
/// service surface (chat=.medium, kb-compile=.low, etc.) can opt into a
/// different routing tier. The `modelID` from the selected `ModelRoute`
/// is rewritten into the payload before dispatch, so the upstream sees
/// the model the table picked rather than the original user hint.
struct RoutedLLMTransport: HermesChatTransport {
    let registry: ProviderRegistry
    let router: any ModelRouter
    let capability: LLMCapabilityLevel
    let logger: Logger

    let usageMeter: UsageMeterService?
    /// USD meter for *managed* traffic — calls the platform's own key pays
    /// for. Optional so test and single-gateway wirings can skip the write.
    ///
    /// Deliberately not consulted for BYOK: the tenant is billed by the
    /// provider directly, so metering it here would invent a cost we never
    /// incur and make "what does a user cost" answer wrongly in the
    /// expensive direction.
    let costLedger: CostLedgerService?
    /// Records what the turn actually did — which model, which tools.
    /// Optional so test and minimal wirings behave exactly as before.
    let traceRecorder: AgentTurnTraceRecorder?
    /// HER-252 — append-only telemetry sink for failover events. Optional
    /// so non-production wirings (tests, single-gateway deployments)
    /// can skip the DB write.
    let failoverLogger: ProviderFailoverLogger?
    let routerTelemetry: RouterTelemetryService?
    let parallelExecutor: ParallelExecutor

    /// Optional callable that resolves a `User` from the current request
    /// scope. Defaults to the `LLMRoutingContext` task-local so middleware
    /// can thread the authenticated user without restructuring every
    /// service signature.
    let currentUser: @Sendable () async -> User?

    init(
        registry: ProviderRegistry,
        router: any ModelRouter,
        capability: LLMCapabilityLevel = .medium,
        currentUser: @escaping @Sendable () async -> User? = { LLMRoutingContext.currentUser },
        logger: Logger,
        usageMeter: UsageMeterService? = nil,
        costLedger: CostLedgerService? = nil,
        traceRecorder: AgentTurnTraceRecorder? = nil,
        failoverLogger: ProviderFailoverLogger? = nil,
        routerTelemetry: RouterTelemetryService? = nil,
        parallelExecutor: ParallelExecutor? = nil
    ) {
        self.registry = registry
        self.router = router
        self.capability = capability
        self.currentUser = currentUser
        self.logger = logger
        self.usageMeter = usageMeter
        self.costLedger = costLedger
        self.traceRecorder = traceRecorder
        self.failoverLogger = failoverLogger
        self.routerTelemetry = routerTelemetry
        self.parallelExecutor = parallelExecutor ?? ParallelExecutor(
            registry: registry,
            logger: logger,
            store: nil
        )
    }

    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, sessionKey: sessionKey, sessionID: sessionID).data
    }

    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
        let requestedModel = Self.extractModel(from: payload)
        let user = await currentUser()
        let prompt = Self.extractLatestUserPrompt(from: payload)
        var decision = await LLMRoutingContext.$cerberusPrompt.withValue(prompt) {
            await router.pick(forModel: requestedModel, capability: capability, user: user)
        }
        if let forced = LLMRoutingContext.forcedRoute,
           let provider = ProviderKind(shared: forced.provider)
        {
            decision = RouteDecision(
                primary: ModelRoute(provider: provider, modelID: forced.model),
                fallbacks: [],
                // Preserve who pays. Dropping this would reset the request to
                // "no declared intent" — i.e. managed — and let an "Ask another
                // model" turn from a BYOK user spend the platform key.
                credentialMode: decision.credentialMode ?? decision.cerberus?.mode
            )
        }
        if let cerberus = decision.cerberus {
            if cerberus.byokKeysRequired {
                throw BYOKKeysRequiredError()
            }
            if cerberus.freeLaneExhausted {
                throw FreeLaneExhaustedError(retryAfterSeconds: cerberus.freeLaneRetryAfterSeconds)
            }
            guard !cerberus.budgetDenied else { throw UsageCapExceededError(retryAfter: 3600) }
            publishRouting(cerberus, phase: .selected, routes: cerberus.routes)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var fallbackCount = 0

        if let cerberus = decision.cerberus, cerberus.strategy == .ensemble,
           let ensemble = try? await parallelExecutor.execute(
               payload: payload,
               sessionKey: sessionKey,
               sessionID: sessionID,
               metadata: cerberus,
               requestedStrategy: LLMRoutingContext.parallelRequest?.strategy,
               requestedParticipants: LLMRoutingContext.parallelRequest?.participants,
               customSynthesisPrompt: LLMRoutingContext.parallelRequest?.synthesisPrompt,
               prompt: prompt
           )
        {
            if let routerTelemetry {
                let result = RouterExecutionResult(
                    provider: ensemble.route.provider,
                    model: ensemble.route.modelID,
                    status: ensemble.status == .completed ? "ok" : ensemble.status.rawValue,
                    tokensIn: ensemble.tokensIn,
                    tokensOut: ensemble.tokensOut,
                    estimatedCostUsdMicros: ensemble.estimatedCostUsdMicros,
                    latencyMs: ensemble.latencyMs,
                    usageEstimated: true,
                    fallbackCount: 0
                )
                await routerTelemetry.complete(metadata: cerberus, result: result)
                publishUsage(cerberus, result: result)
            }
            Self.publishRouteOutcome(ensemble.route, cerberus: decision.cerberus)
            return ensemble.metadata
        }
        if let cerberus = decision.cerberus,
           cerberus.strategy == .ensemble,
           LLMRoutingContext.parallelStrategy != nil
        {
            if let routerTelemetry {
                await routerTelemetry.release(
                    tenantID: cerberus.tenantID,
                    reservedUsdMicros: cerberus.budgetReservationUsdMicros
                )
            }
            throw UpstreamErrorResponse(
                reasonCode: "parallel_quorum_failed",
                userMessage: "Not enough models completed to synthesize this answer."
            )
        }

        // HER-252 — track the most recent recoverable failure so when the
        // next candidate succeeds we can build a ProviderFailoverNotice
        // describing the transition. Reset on each new candidate so we
        // only ever emit one notice per actual failover.
        var lastRecoverable: (any Error)?
        var lastFailedCandidate: (route: ModelRoute, error: ProviderError)?
        let userID: UUID? = (try? user?.requireID())
        let source: ProviderFailoverNotice.TelemetrySource =
            (LLMRoutingContext.currentResolution?.isUserOverride == true) ? .byo : .hosted

        for candidate in decision.candidates {
            guard let adapter = await registry.adapter(for: candidate.provider) else {
                logger.warning("router decision had unregistered provider: \(candidate.provider.rawValue)")
                continue
            }
            let candidatePayload = Self.rewriteModel(candidate.modelID, in: payload)
            do {
                let credentialMode = decision.credentialMode
                    ?? decision.cerberus?.mode
                    ?? LLMRoutingContext.credentialMode
                let metadata = try await LLMRoutingContext.$credentialMode.withValue(credentialMode) {
                    try await adapter.chatCompletionsWithMetadata(
                        payload: candidatePayload,
                        sessionKey: sessionKey,
                        sessionID: sessionID
                    )
                }
                // HER-252 — successful candidate. If we got here by falling
                // over from a prior failure, emit + log a notice describing
                // the transition.
                if let prior = lastFailedCandidate {
                    fallbackCount += 1
                    publishFailover(
                        original: prior.route,
                        originalError: prior.error,
                        fallback: candidate,
                        tenantID: userID,
                        source: source
                    )
                }
                if usageMeter != nil || costLedger != nil, let user {
                    var mtokIn = 0
                    var mtokOut = 0
                    Self.extractUsage(from: metadata, mtokIn: &mtokIn, mtokOut: &mtokOut)
                    if mtokIn > 0 || mtokOut > 0, let userID = try? user.requireID() {
                        // Both meters read these, and the token meter's `Task`
                        // captures them, so bind immutable copies — sending a
                        // closure that captures the `var`s races the read below.
                        let tokensIn = mtokIn
                        let tokensOut = mtokOut
                        let modelToRecord = candidate.modelID
                        let billingID = LLMRoutingContext.billingTenantID ?? userID
                        if let meter = usageMeter {
                            Task { await meter.record(tenantID: billingID, model: modelToRecord, tokensIn: tokensIn, tokensOut: tokensOut) }
                        }
                        // `cost_ledger` is the only USD-denominated meter we
                        // have; `usage_meter` counts tokens, which cannot be
                        // compared across providers whose rates differ by two
                        // orders of magnitude. BYOK is skipped on purpose —
                        // the user pays that provider directly.
                        if let ledger = costLedger,
                           let charge = Self.ledgerCharge(
                               credentialMode: credentialMode,
                               provider: candidate.provider,
                               model: modelToRecord,
                               tokensIn: tokensIn,
                               tokensOut: tokensOut,
                               cerberus: decision.cerberus
                           )
                        {
                            Task {
                                await ledger.record(
                                    tenantID: billingID,
                                    provider: charge.provider,
                                    usdMicros: charge.usdMicros
                                )
                            }
                        }
                    }
                }
                // The trace is written whether or not the upstream reported
                // usage: a turn with no token counts still chose a model and
                // may have called tools, which is the part a user can see.
                if let traceRecorder, let user, let tenantID = try? user.requireID(),
                   let providerID = candidate.provider.toShared()
                {
                    var traceIn = 0
                    var traceOut = 0
                    Self.extractUsage(from: metadata, mtokIn: &traceIn, mtokOut: &traceOut)
                    let toolNames = OpenAICompletionReader.assistantMessage(from: metadata.data)
                        .map { OpenAICompletionReader.toolCallNames(in: $0) }
                    let turn = AgentTurnTraceRecorder.Turn(
                        tenantID: LLMRoutingContext.billingTenantID ?? tenantID,
                        conversationMessageID: LLMRoutingContext.conversationMessageID,
                        provider: providerID,
                        model: candidate.modelID,
                        toolNames: toolNames,
                        failoverCount: fallbackCount,
                        tokensIn: traceIn,
                        tokensOut: traceOut,
                        estimatedCostUsdMicros: Self.catalogCost(
                            provider: providerID,
                            model: candidate.modelID,
                            tokensIn: traceIn,
                            tokensOut: traceOut,
                            cerberus: decision.cerberus
                        ),
                        latencyMs: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000),
                        credentialMode: credentialMode
                    )
                    Task { await traceRecorder.record(turn) }
                }
                if let cerberus = decision.cerberus, let routerTelemetry {
                    var tokensIn = 0
                    var tokensOut = 0
                    Self.extractUsage(from: metadata, mtokIn: &tokensIn, mtokOut: &tokensOut)
                    let estimated = tokensIn == 0 && tokensOut == 0
                    if estimated {
                        tokensIn = max(1, prompt.count / 4)
                        tokensOut = max(1, metadata.data.count / 4)
                    }
                    let cost = Self.estimatedCost(
                        provider: candidate.provider,
                        model: candidate.modelID,
                        tokensIn: tokensIn,
                        tokensOut: tokensOut,
                        metadata: cerberus
                    )
                    let latency = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    let result = RouterExecutionResult(
                        provider: candidate.provider,
                        model: candidate.modelID,
                        status: "ok",
                        tokensIn: tokensIn,
                        tokensOut: tokensOut,
                        estimatedCostUsdMicros: cost,
                        latencyMs: latency,
                        usageEstimated: estimated,
                        fallbackCount: fallbackCount
                    )
                    await routerTelemetry.complete(metadata: cerberus, result: result)
                    publishUsage(cerberus, result: result)
                }
                Self.publishRouteOutcome(candidate, cerberus: decision.cerberus)
                return metadata
            } catch let providerError as ProviderError where providerError.isRecoverable {
                lastRecoverable = providerError
                lastFailedCandidate = (candidate, providerError)
                logger.warning("provider \(candidate.provider.rawValue) failed (\(providerError.reasonCode)): \(providerError)")
                continue
            } catch let providerError as ProviderError {
                logger.error("provider \(candidate.provider.rawValue) permanent: \(providerError)")
                UpstreamErrorTelemetry.record(reasonCode: providerError.reasonCode, provider: candidate.provider.rawValue)
                if let cerberus = decision.cerberus, let routerTelemetry {
                    await routerTelemetry.release(
                        tenantID: cerberus.tenantID,
                        reservedUsdMicros: cerberus.budgetReservationUsdMicros
                    )
                }
                throw UpstreamErrorResponse(
                    reasonCode: providerError.reasonCode,
                    userMessage: providerError.userMessage,
                    retryAfterMs: Self.retryHint(for: providerError.reasonCode)
                )
            } catch let fatal as BYOKKeysRequiredError {
                // Fail closed. Not a `ProviderError`, so without this branch it
                // would land in the generic catch below, be treated as
                // recoverable, and the loop would advance — turning the 403
                // `byok_keys_required` envelope (with its add_key /
                // switch_to_managed CTAs) into a generic `upstream_error`.
                // Every remaining candidate has the same missing credential.
                if let cerberus = decision.cerberus, let routerTelemetry {
                    await routerTelemetry.release(
                        tenantID: cerberus.tenantID,
                        reservedUsdMicros: cerberus.budgetReservationUsdMicros
                    )
                }
                throw fatal
            } catch {
                lastRecoverable = error
                logger.warning("provider \(candidate.provider.rawValue) unclassified error: \(error)")
                continue
            }
        }
        logger.error("all providers exhausted for decision \(decision.candidates)")
        if let cerberus = decision.cerberus, let routerTelemetry {
            await routerTelemetry.release(
                tenantID: cerberus.tenantID,
                reservedUsdMicros: cerberus.budgetReservationUsdMicros
            )
        }
        if let lastFailedCandidate {
            UpstreamErrorTelemetry.record(
                reasonCode: lastFailedCandidate.error.reasonCode,
                provider: lastFailedCandidate.route.provider.rawValue
            )
            throw UpstreamErrorResponse(
                reasonCode: lastFailedCandidate.error.reasonCode,
                userMessage: lastFailedCandidate.error.userMessage,
                retryAfterMs: Self.retryHint(for: lastFailedCandidate.error.reasonCode)
            )
        }
        if lastRecoverable != nil {
            // Only unclassified (non-ProviderError) recoverable failures.
            // No typed reasonCode/userMessage available; emit generic.
            UpstreamErrorTelemetry.record(reasonCode: "upstream_error", provider: "unknown")
            throw UpstreamErrorResponse(
                reasonCode: "upstream_error",
                userMessage: "LLM upstream failed."
            )
        }
        UpstreamErrorTelemetry.record(reasonCode: "no_providers", provider: "n/a")
        throw UpstreamErrorResponse(
            reasonCode: "no_providers",
            userMessage: "No LLM provider available."
        )
    }

    // MARK: - Streaming (P2)

    /// Streaming counterpart to `chatCompletionsWithMetadata`. Walks the
    /// same routing decision, but the failover window closes at the first
    /// yielded chunk: before it, recoverable `ProviderError`s advance to
    /// the next candidate exactly like the buffered path; after it, errors
    /// terminate the stream (partial output already reached the client).
    /// Usage metering is skipped — streamed responses don't reliably carry
    /// usage blocks across providers.
    func chatStream(payload: Data, sessionKey: String, sessionID: String?) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            let requestedModel = Self.extractModel(from: payload)
            let user = await currentUser()
            let prompt = Self.extractLatestUserPrompt(from: payload)
            var decision = await LLMRoutingContext.$cerberusPrompt.withValue(prompt) {
                await router.pick(forModel: requestedModel, capability: capability, user: user)
            }
            if let forced = LLMRoutingContext.forcedRoute,
               let provider = ProviderKind(shared: forced.provider)
            {
                decision = RouteDecision(
                    primary: ModelRoute(provider: provider, modelID: forced.model),
                    fallbacks: [],
                    // Preserve who pays — see the buffered path.
                    credentialMode: decision.credentialMode ?? decision.cerberus?.mode
                )
            }
            if let cerberus = decision.cerberus {
                if cerberus.byokKeysRequired {
                    continuation.finish(throwing: BYOKKeysRequiredError())
                    return
                }
                if cerberus.freeLaneExhausted {
                    continuation.finish(throwing: FreeLaneExhaustedError(
                        retryAfterSeconds: cerberus.freeLaneRetryAfterSeconds
                    ))
                    return
                }
                guard !cerberus.budgetDenied else {
                    continuation.finish(throwing: UsageCapExceededError(retryAfter: 3600))
                    return
                }
                publishRouting(cerberus, phase: .selected, routes: cerberus.routes)
            }
            let started = DispatchTime.now().uptimeNanoseconds
            var outputCharacters = 0
            var fallbackCount = 0

            if let cerberus = decision.cerberus, cerberus.strategy == .ensemble,
               let ensemble = try? await parallelExecutor.execute(
                   payload: payload,
                   sessionKey: sessionKey,
                   sessionID: sessionID,
                   metadata: cerberus,
                   requestedStrategy: LLMRoutingContext.parallelRequest?.strategy,
                   requestedParticipants: LLMRoutingContext.parallelRequest?.participants,
                   customSynthesisPrompt: LLMRoutingContext.parallelRequest?.synthesisPrompt,
                   prompt: prompt
               )
            {
                let content = ProviderStreamKit.extractContent(from: ensemble.metadata.data)
                continuation.yield(ChatStreamChunk(delta: content, finishReason: "stop"))
                if let routerTelemetry {
                    let result = RouterExecutionResult(
                        provider: ensemble.route.provider,
                        model: ensemble.route.modelID,
                        status: ensemble.status == .completed ? "ok" : ensemble.status.rawValue,
                        tokensIn: ensemble.tokensIn,
                        tokensOut: ensemble.tokensOut,
                        estimatedCostUsdMicros: ensemble.estimatedCostUsdMicros,
                        latencyMs: ensemble.latencyMs,
                        usageEstimated: true,
                        fallbackCount: 0
                    )
                    await routerTelemetry.complete(metadata: cerberus, result: result)
                    publishUsage(cerberus, result: result)
                }
                Self.publishRouteOutcome(ensemble.route, cerberus: decision.cerberus)
                continuation.finish()
                return
            }
            if let cerberus = decision.cerberus,
               cerberus.strategy == .ensemble,
               LLMRoutingContext.parallelStrategy != nil
            {
                if let routerTelemetry {
                    await routerTelemetry.release(
                        tenantID: cerberus.tenantID,
                        reservedUsdMicros: cerberus.budgetReservationUsdMicros
                    )
                }
                continuation.finish(throwing: UpstreamErrorResponse(
                    reasonCode: "parallel_quorum_failed",
                    userMessage: "Not enough models completed to synthesize this answer."
                ))
                return
            }

            var lastFailedCandidate: (route: ModelRoute, error: ProviderError)?
            var sawUnclassifiedFailure = false
            let userID: UUID? = (try? user?.requireID())
            let source: ProviderFailoverNotice.TelemetrySource =
                (LLMRoutingContext.currentResolution?.isUserOverride == true) ? .byo : .hosted

            for candidate in decision.candidates {
                guard let adapter = await registry.adapter(for: candidate.provider) else {
                    logger.warning("router decision had unregistered provider: \(candidate.provider.rawValue)")
                    continue
                }
                let candidatePayload = Self.rewriteModel(candidate.modelID, in: payload)
                var yieldedAny = false
                do {
                    let credentialMode = decision.credentialMode
                        ?? decision.cerberus?.mode
                        ?? LLMRoutingContext.credentialMode
                    let candidateStream = LLMRoutingContext.$credentialMode.withValue(credentialMode) {
                        adapter.chatStream(
                            payload: candidatePayload,
                            sessionKey: sessionKey,
                            sessionID: sessionID
                        )
                    }
                    for try await chunk in candidateStream {
                        if !yieldedAny {
                            yieldedAny = true
                            if let prior = lastFailedCandidate {
                                fallbackCount += 1
                                publishFailover(
                                    original: prior.route,
                                    originalError: prior.error,
                                    fallback: candidate,
                                    tenantID: userID,
                                    source: source
                                )
                            }
                        }
                        outputCharacters += chunk.delta.count
                        continuation.yield(chunk)
                    }
                    if yieldedAny {
                        if let cerberus = decision.cerberus, let routerTelemetry {
                            let tokensIn = max(1, prompt.count / 4)
                            let tokensOut = max(1, outputCharacters / 4)
                            let cost = Self.estimatedCost(
                                provider: candidate.provider,
                                model: candidate.modelID,
                                tokensIn: tokensIn,
                                tokensOut: tokensOut,
                                metadata: cerberus
                            )
                            let result = RouterExecutionResult(
                                provider: candidate.provider,
                                model: candidate.modelID,
                                status: "ok",
                                tokensIn: tokensIn,
                                tokensOut: tokensOut,
                                estimatedCostUsdMicros: cost,
                                latencyMs: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000),
                                usageEstimated: true,
                                fallbackCount: fallbackCount
                            )
                            await routerTelemetry.complete(metadata: cerberus, result: result)
                            publishUsage(cerberus, result: result)
                        }
                        Self.publishRouteOutcome(candidate, cerberus: decision.cerberus)
                        continuation.finish()
                        return
                    }
                    // 2xx stream that produced zero chunks — treat like a
                    // transient failure and try the next candidate.
                    let empty = ProviderError.transient(provider: candidate.provider, status: 0, body: "empty stream")
                    lastFailedCandidate = (candidate, empty)
                    logger.warning("provider \(candidate.provider.rawValue) streamed no chunks; failing over")
                    continue
                } catch let providerError as ProviderError where providerError.isRecoverable && !yieldedAny {
                    lastFailedCandidate = (candidate, providerError)
                    logger.warning("provider \(candidate.provider.rawValue) stream failed (\(providerError.reasonCode)): \(providerError)")
                    continue
                } catch let providerError as ProviderError where !yieldedAny {
                    logger.error("provider \(candidate.provider.rawValue) stream permanent: \(providerError)")
                    UpstreamErrorTelemetry.record(reasonCode: providerError.reasonCode, provider: candidate.provider.rawValue)
                    if let cerberus = decision.cerberus, let routerTelemetry {
                        await routerTelemetry.release(
                            tenantID: cerberus.tenantID,
                            reservedUsdMicros: cerberus.budgetReservationUsdMicros
                        )
                    }
                    continuation.finish(throwing: UpstreamErrorResponse(
                        reasonCode: providerError.reasonCode,
                        userMessage: providerError.userMessage,
                        retryAfterMs: Self.retryHint(for: providerError.reasonCode)
                    ))
                    return
                } catch let fatal as BYOKKeysRequiredError {
                    // Fail closed — see the buffered loop. Every remaining
                    // candidate is missing the same credential, so failing over
                    // only converts a precise 403 into a generic upstream error.
                    if let cerberus = decision.cerberus, let routerTelemetry {
                        await routerTelemetry.release(
                            tenantID: cerberus.tenantID,
                            reservedUsdMicros: cerberus.budgetReservationUsdMicros
                        )
                    }
                    continuation.finish(throwing: fatal)
                    return
                } catch {
                    if yieldedAny {
                        // Mid-stream failure after partial output: no
                        // failover — surface it so the client can retry.
                        continuation.finish(throwing: error)
                        return
                    }
                    sawUnclassifiedFailure = true
                    logger.warning("provider \(candidate.provider.rawValue) stream unclassified error: \(error)")
                    continue
                }
            }

            logger.error("all providers exhausted for streaming decision \(decision.candidates)")
            if let cerberus = decision.cerberus, let routerTelemetry {
                await routerTelemetry.release(
                    tenantID: cerberus.tenantID,
                    reservedUsdMicros: cerberus.budgetReservationUsdMicros
                )
            }
            if let lastFailedCandidate {
                UpstreamErrorTelemetry.record(
                    reasonCode: lastFailedCandidate.error.reasonCode,
                    provider: lastFailedCandidate.route.provider.rawValue
                )
                continuation.finish(throwing: UpstreamErrorResponse(
                    reasonCode: lastFailedCandidate.error.reasonCode,
                    userMessage: lastFailedCandidate.error.userMessage,
                    retryAfterMs: Self.retryHint(for: lastFailedCandidate.error.reasonCode)
                ))
            } else if sawUnclassifiedFailure {
                UpstreamErrorTelemetry.record(reasonCode: "upstream_error", provider: "unknown")
                continuation.finish(throwing: UpstreamErrorResponse(
                    reasonCode: "upstream_error",
                    userMessage: "LLM upstream failed."
                ))
            } else {
                UpstreamErrorTelemetry.record(reasonCode: "no_providers", provider: "n/a")
                continuation.finish(throwing: UpstreamErrorResponse(
                    reasonCode: "no_providers",
                    userMessage: "No LLM provider available."
                ))
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// HER-252 — publish a `ProviderFailoverNotice` to both the SSE sink
    /// (via task-local `FailoverNoticeContext`) and the persistent
    /// telemetry logger (if wired). Best-effort; never throws.
    private func publishFailover(
        original: ModelRoute,
        originalError: ProviderError,
        fallback: ModelRoute,
        tenantID: UUID?,
        source: ProviderFailoverNotice.TelemetrySource
    ) {
        let statusCode: Int? = switch originalError {
        case let .transient(_, status, _): status
        case let .permanent(_, status, _): status
        case let .creditExhausted(_, status, _): status
        case .network: nil
        }
        let bodyPreview: String? = switch originalError {
        case let .transient(_, _, body): body
        case let .permanent(_, _, body): body
        case let .creditExhausted(_, _, body): body
        case .network: nil
        }
        let notice = ProviderFailoverNotice(
            originalProvider: original.provider,
            originalModel: original.modelID,
            fallbackProvider: fallback.provider,
            fallbackModel: fallback.modelID,
            reasonCode: originalError.reasonCode,
            userMessage: originalError.userMessage,
            statusCode: statusCode,
            bodyPreview: bodyPreview,
            source: source
        )
        FailoverNoticeContext.sink?(notice)
        failoverLogger?.record(notice: notice, tenantID: tenantID)
    }

    // MARK: - Helpers

    /// Cheap best-effort pull of the `model` field from the chat-completions
    /// JSON payload. Used as a hint for the router; nil if unparseable.
    private static func extractModel(from payload: Data) -> String? {
        guard
            let any = try? JSONSerialization.jsonObject(with: payload),
            let dict = any as? [String: Any],
            let model = dict["model"] as? String,
            !model.isEmpty
        else {
            return nil
        }
        return model
    }

    private static func extractLatestUserPrompt(from payload: Data) -> String {
        guard let dictionary = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let messages = dictionary["messages"] as? [[String: Any]]
        else { return "" }
        return messages.reversed().first { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
    }

    private func publishRouting(
        _ metadata: CerberusDecisionMetadata,
        phase: RouterEventPhase,
        routes: [RouterModelRouteDTO]
    ) {
        CerberusStreamContext.sink?(.routing(RouterRoutingEventDTO(
            executionID: metadata.executionID,
            phase: phase,
            profileID: metadata.profileID,
            profileName: metadata.profileName,
            taskType: metadata.taskType,
            strategy: metadata.strategy,
            activeRoutes: routes
        )))
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
        return catalogCost(
            provider: shared,
            model: model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            cerberus: metadata
        )
    }

    /// What, if anything, to write to `cost_ledger` for a completed call.
    ///
    /// `nil` means "record nothing", for three distinct reasons that all
    /// deserve the same silence:
    ///
    /// - **BYOK.** The tenant is billed by the provider directly. Metering it
    ///   here would invent a cost we never incur and make the ledger answer
    ///   "what does this user cost" wrongly, in the expensive direction.
    /// - **A provider with no `ProviderID`.** Nothing to key the row on.
    /// - **A model with no known rate.** A guessed price is worse than no
    ///   row: the ledger's only job is to be truthful about money.
    static func ledgerCharge(
        credentialMode: LLMBrainMode?,
        provider: ProviderKind,
        model: String,
        tokensIn: Int,
        tokensOut: Int,
        cerberus: CerberusDecisionMetadata?
    ) -> (provider: ProviderID, usdMicros: Int64)? {
        guard credentialMode != .byok else { return nil }
        guard let providerID = provider.toShared() else { return nil }
        let usd = catalogCost(
            provider: providerID,
            model: model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            cerberus: cerberus
        )
        guard usd > 0 else { return nil }
        return (providerID, usd)
    }

    /// Micro-USD for a call, from the router's own price table.
    ///
    /// The decision's routes carry the rate actually quoted for this request,
    /// so they win; `RouterModelCatalog` is the fallback for a call that never
    /// went through Cerberus. A model in neither yields 0 — recording a
    /// guessed price would be worse than recording nothing, because the
    /// ledger's only job is to answer "what does a user cost" truthfully.
    static func catalogCost(
        provider: ProviderID,
        model: String,
        tokensIn: Int,
        tokensOut: Int,
        cerberus: CerberusDecisionMetadata?
    ) -> Int64 {
        let route = cerberus?.routes.first { $0.provider == provider && $0.model == model }
        let catalog = RouterModelCatalog.entry(provider: provider, model: model)
        let inputRate = route?.inputPerMillionUsdMicros ?? catalog?.inputPerMillionUsdMicros ?? 0
        let outputRate = route?.outputPerMillionUsdMicros ?? catalog?.outputPerMillionUsdMicros ?? 0
        return Int64(max(0, tokensIn)) * inputRate / 1_000_000
            + Int64(max(0, tokensOut)) * outputRate / 1_000_000
    }

    private static func publishRouteOutcome(_ route: ModelRoute, cerberus: CerberusDecisionMetadata? = nil) {
        LLMRoutingContext.routeOutcomeSink?(
            ModelProvenanceDTO(
                provider: route.provider.rawValue,
                model: route.modelID,
                reason: cerberus?.reason,
                routingPolicy: cerberus?.routingPolicy,
                complexity: cerberus?.complexity,
                taskType: cerberus?.taskType
            )
        )
    }

    /// Rewrites the `model` field in the chat-completions payload so the
    /// upstream sees the model the router actually picked. Falls through
    /// on any parse failure rather than mangling the request.
    private static func rewriteModel(_ modelID: String, in payload: Data) -> Data {
        guard var dict = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return payload
        }
        dict["model"] = modelID
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? payload
    }

    private static func extractUsage(
        from metadata: HermesChatTransportMetadata,
        mtokIn: inout Int,
        mtokOut: inout Int
    ) {
        let lower = Dictionary(uniqueKeysWithValues: metadata.headers.map { ($0.key.lowercased(), $0.value) })
        for name in ["x-mtok-in", "x-usage-mtok-in", "x-luminavault-mtok-in"] {
            if let raw = lower[name], let value = Int(raw) {
                mtokIn = value
                break
            }
        }
        for name in ["x-mtok-out", "x-usage-mtok-out", "x-luminavault-mtok-out"] {
            if let raw = lower[name], let value = Int(raw) {
                mtokOut = value
                break
            }
        }

        if mtokIn == 0, mtokOut == 0 {
            if let responseJSON = try? JSONSerialization.jsonObject(with: metadata.data) as? [String: Any],
               let usage = responseJSON["usage"] as? [String: Any]
            {
                mtokIn = (usage["prompt_tokens"] as? Int) ?? 0
                mtokOut = (usage["completion_tokens"] as? Int) ?? 0
            }
        }
    }

    private static func retryHint(for reasonCode: String) -> Int? {
        reasonCode == "upstream_timeout" ? UpstreamErrorResponse.timeoutRetryHintMs : nil
    }
}
