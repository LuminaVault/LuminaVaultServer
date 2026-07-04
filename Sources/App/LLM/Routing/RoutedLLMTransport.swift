import Foundation
import Hummingbird
import Logging
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
    /// HER-252 — append-only telemetry sink for failover events. Optional
    /// so non-production wirings (tests, single-gateway deployments)
    /// can skip the DB write.
    let failoverLogger: ProviderFailoverLogger?

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
        failoverLogger: ProviderFailoverLogger? = nil
    ) {
        self.registry = registry
        self.router = router
        self.capability = capability
        self.currentUser = currentUser
        self.logger = logger
        self.usageMeter = usageMeter
        self.failoverLogger = failoverLogger
    }

    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, sessionKey: sessionKey, sessionID: sessionID).data
    }

    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
        let requestedModel = Self.extractModel(from: payload)
        let user = await currentUser()
        let decision = await router.pick(forModel: requestedModel, capability: capability, user: user)

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
                let metadata = try await adapter.chatCompletionsWithMetadata(payload: candidatePayload, sessionKey: sessionKey, sessionID: sessionID)
                // HER-252 — successful candidate. If we got here by falling
                // over from a prior failure, emit + log a notice describing
                // the transition.
                if let prior = lastFailedCandidate {
                    publishFailover(
                        original: prior.route,
                        originalError: prior.error,
                        fallback: candidate,
                        tenantID: userID,
                        source: source
                    )
                }
                if let usageMeter, let user {
                    var mtokIn = 0
                    var mtokOut = 0
                    Self.extractUsage(from: metadata, mtokIn: &mtokIn, mtokOut: &mtokOut)
                    if mtokIn > 0 || mtokOut > 0, let userID = try? user.requireID() {
                        let meter = usageMeter
                        let modelToRecord = candidate.modelID
                        Task { await meter.record(tenantID: userID, model: modelToRecord, tokensIn: mtokIn, tokensOut: mtokOut) }
                    }
                }
                return metadata
            } catch let providerError as ProviderError where providerError.isRecoverable {
                lastRecoverable = providerError
                lastFailedCandidate = (candidate, providerError)
                logger.warning("provider \(candidate.provider.rawValue) failed (\(providerError.reasonCode)): \(providerError)")
                continue
            } catch let providerError as ProviderError {
                logger.error("provider \(candidate.provider.rawValue) permanent: \(providerError)")
                UpstreamErrorTelemetry.record(reasonCode: providerError.reasonCode, provider: candidate.provider.rawValue)
                throw UpstreamErrorResponse(
                    reasonCode: providerError.reasonCode,
                    userMessage: providerError.userMessage,
                    retryAfterMs: Self.retryHint(for: providerError.reasonCode)
                )
            } catch {
                lastRecoverable = error
                logger.warning("provider \(candidate.provider.rawValue) unclassified error: \(error)")
                continue
            }
        }
        logger.error("all providers exhausted for decision \(decision.candidates)")
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
            let decision = await router.pick(forModel: requestedModel, capability: capability, user: user)

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
                    for try await chunk in adapter.chatStream(
                        payload: candidatePayload,
                        sessionKey: sessionKey,
                        sessionID: sessionID
                    ) {
                        if !yieldedAny {
                            yieldedAny = true
                            if let prior = lastFailedCandidate {
                                publishFailover(
                                    original: prior.route,
                                    originalError: prior.error,
                                    fallback: candidate,
                                    tenantID: userID,
                                    source: source
                                )
                            }
                        }
                        continuation.yield(chunk)
                    }
                    if yieldedAny {
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
                    continuation.finish(throwing: UpstreamErrorResponse(
                        reasonCode: providerError.reasonCode,
                        userMessage: providerError.userMessage,
                        retryAfterMs: Self.retryHint(for: providerError.reasonCode)
                    ))
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
