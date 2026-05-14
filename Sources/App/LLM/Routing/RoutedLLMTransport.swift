import Foundation
import Hummingbird
import Logging

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
    ) {
        self.registry = registry
        self.router = router
        self.capability = capability
        self.currentUser = currentUser
        self.logger = logger
        self.usageMeter = usageMeter
    }

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername).data
    }

    func chatCompletionsWithMetadata(payload: Data, profileUsername: String) async throws -> HermesChatTransportMetadata {
        let requestedModel = Self.extractModel(from: payload)
        let user = await currentUser()
        let decision = await router.pick(forModel: requestedModel, capability: capability, user: user)

        var lastRecoverable: (any Error)?
        for candidate in decision.candidates {
            guard let adapter = await registry.adapter(for: candidate.provider) else {
                logger.warning("router decision had unregistered provider: \(candidate.provider.rawValue)")
                continue
            }
            let candidatePayload = Self.rewriteModel(candidate.modelID, in: payload)
            do {
                let metadata = try await adapter.chatCompletionsWithMetadata(payload: candidatePayload, profileUsername: profileUsername)
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
                logger.warning("provider \(candidate.provider.rawValue) failed (recoverable): \(providerError)")
                continue
            } catch let providerError as ProviderError {
                logger.error("provider \(candidate.provider.rawValue) permanent: \(providerError)")
                throw HTTPError(
                    .badGateway,
                    message: "llm upstream rejected request (\(candidate.provider.rawValue))",
                )
            } catch {
                lastRecoverable = error
                logger.warning("provider \(candidate.provider.rawValue) unclassified error: \(error)")
                continue
            }
        }
        logger.error("all providers exhausted for decision \(decision.candidates)")
        if let lastRecoverable {
            throw HTTPError(.badGateway, message: "llm upstream unavailable: \(lastRecoverable)")
        }
        throw HTTPError(.badGateway, message: "llm upstream unavailable: no providers")
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
        mtokOut: inout Int,
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
}
