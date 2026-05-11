import Foundation
import Hummingbird
import Logging

/// HER-165 — `HermesChatTransport` adapter that fans out to the routing
/// foundation. Asks `ModelRouter` for a decision, walks the candidates,
/// stops on first 2xx, fails over on `.transient` / `.network`, gives up
/// on `.permanent`.
///
/// Drop-in for `URLSessionHermesChatTransport` — every service that
/// previously held `any HermesChatTransport` keeps working. Today the
/// router returns `[.hermesGateway]` so behaviour is unchanged from the
/// single-gateway path; HER-161 will start producing multi-candidate
/// decisions and this transport already knows what to do with them.
struct RoutedLLMTransport: HermesChatTransport {
    let registry: ProviderRegistry
    let router: any ModelRouter
    let logger: Logger

    /// Optional callable that resolves a `User` from the current request
    /// scope. Today the chat path is decoupled from per-user routing —
    /// services hold a `tenantID` but not a full `User` — so this is
    /// injected nil in production and the router does cost / privacy
    /// routing without it. HER-161 will thread the user through.
    let currentUser: @Sendable () async -> User?

    init(
        registry: ProviderRegistry,
        router: any ModelRouter,
        currentUser: @escaping @Sendable () async -> User? = { nil },
        logger: Logger,
    ) {
        self.registry = registry
        self.router = router
        self.currentUser = currentUser
        self.logger = logger
    }

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        let requestedModel = Self.extractModel(from: payload)
        let user = await currentUser()
        let decision = await router.pick(forModel: requestedModel, user: user)

        var lastRecoverable: (any Error)?
        for candidate in decision.candidates {
            guard let adapter = await registry.adapter(for: candidate) else {
                logger.warning("router decision had unregistered provider: \(candidate.rawValue)")
                continue
            }
            do {
                return try await adapter.chatCompletions(payload: payload, profileUsername: profileUsername)
            } catch let providerError as ProviderError where providerError.isRecoverable {
                lastRecoverable = providerError
                logger.warning("provider \(candidate.rawValue) failed (recoverable): \(providerError)")
                continue
            } catch let providerError as ProviderError {
                // .permanent — caller's payload is wrong. Don't fall over.
                logger.error("provider \(candidate.rawValue) permanent: \(providerError)")
                throw HTTPError(
                    .badGateway,
                    message: "llm upstream rejected request (\(candidate.rawValue))",
                )
            } catch {
                // Something we don't classify — treat as recoverable so a
                // single bad adapter doesn't break the user.
                lastRecoverable = error
                logger.warning("provider \(candidate.rawValue) unclassified error: \(error)")
                continue
            }
        }
        // Every candidate failed recoverably (or the registry was empty).
        logger.error("all providers exhausted for decision \(decision.candidates)")
        if let lastRecoverable {
            throw HTTPError(.badGateway, message: "llm upstream unavailable: \(lastRecoverable)")
        }
        throw HTTPError(.badGateway, message: "llm upstream unavailable: no providers")
    }

    // MARK: - Helpers

    /// Cheap best-effort pull of the `model` field from the chat-completions
    /// JSON payload. Used as a hint for the router; nil if unparseable
    /// (router falls back to its default).
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
}
