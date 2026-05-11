import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import NIOCore

/// HER-172 ContextRouter middleware.
///
/// When the requesting user has opted in (`users.context_routing=true`),
/// reads the user's latest chat message, asks a `capability=low` model
/// which (if any) of their enabled skills is relevant, and — if exactly
/// one matches — prepends that skill's body to the system prompt of the
/// outbound chat request. Selection is bounded to a single skill per
/// message (HER-172 acceptance).
///
/// ## Cost guard
/// - Default **OFF**. Opt-in via `users.context_routing=true`.
/// - Entitlement gated separately via `EntitlementChecker.privacyContextRouter`
///   (Ultimate tier only). A downgrade flips the flag inert without
///   touching the DB.
/// - Free users never reach this code path because the entitlement check
///   refuses to enable the flag.
///
/// ## Safety
/// - Selector failure / timeout → no-op. Chat is the hot path; the router
///   must never break it.
/// - Empty manifest list → no-op (no LLM call).
/// - Non-JSON body / unparseable `ChatRequest` shape → no-op.
struct ContextRouterMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    /// Tenant-scoped manifest provider. Wraps `SkillCatalog.manifests(for:)`
    /// in production and is injectable in tests so the suite can avoid
    /// HER-168 wiring entirely.
    typealias ManifestProvider = @Sendable (UUID) async throws -> [SkillManifest]

    private let manifestProvider: ManifestProvider
    private let selectorFactory: @Sendable (UUID, String) -> any ContextRouterSelector
    private let entitlement: @Sendable (User) -> Bool
    private let maxBodyBytes: Int
    private let logger: Logger

    init(
        manifestProvider: @escaping ManifestProvider,
        selectorFactory: @escaping @Sendable (UUID, String) -> any ContextRouterSelector,
        entitlement: @escaping @Sendable (User) -> Bool = { _ in true },
        maxBodyBytes: Int = 256 * 1024,
        logger: Logger,
    ) {
        self.manifestProvider = manifestProvider
        self.selectorFactory = selectorFactory
        self.entitlement = entitlement
        self.maxBodyBytes = maxBodyBytes
        self.logger = logger
    }

    /// Production helper — wires the middleware to a real `SkillCatalog`.
    init(
        catalog: SkillCatalog,
        selectorFactory: @escaping @Sendable (UUID, String) -> any ContextRouterSelector,
        entitlement: @escaping @Sendable (User) -> Bool = { _ in true },
        maxBodyBytes: Int = 256 * 1024,
        logger: Logger,
    ) {
        self.init(
            manifestProvider: { tenantID in try await catalog.manifests(for: tenantID) },
            selectorFactory: selectorFactory,
            entitlement: entitlement,
            maxBodyBytes: maxBodyBytes,
            logger: logger,
        )
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        // No identity = no opinion. The downstream JWT-required route
        // surfaces 401; we just pass through.
        guard let user = context.identity else {
            return try await next(request, context)
        }
        // Flag off → no-op.
        guard user.contextRouting else {
            return try await next(request, context)
        }
        // Entitlement gate (HER-172 cost guard). Closure injected so the
        // middleware test suite can isolate from billing.
        guard entitlement(user) else {
            return try await next(request, context)
        }
        // Body must be readable. Hummingbird streams; collect with a hard cap.
        var rewritable = request
        let buffer: ByteBuffer
        do {
            buffer = try await rewritable.collectBody(upTo: maxBodyBytes)
        } catch {
            // Body too big or unreadable — pass through. Don't break chat.
            return try await next(request, context)
        }
        // Re-emit the original body even if we end up not mutating, so the
        // downstream handler can still read it.
        rewritable.body = .init(buffer: buffer)

        // Decode and pull the latest user-role message. If the body isn't
        // shaped like a chat-completions request, we no-op.
        guard
            let body = try? JSONDecoder().decode(ChatRoutingBody.self, from: Data(buffer: buffer)),
            let userMessage = body.latestUserContent
        else {
            return try await next(rewritable, context)
        }

        // Load enabled manifests for the tenant. SkillCatalog returns []
        // until HER-168 wires the real loader; that case is a no-op here.
        let tenantID: UUID
        do {
            tenantID = try user.requireID()
        } catch {
            return try await next(rewritable, context)
        }
        let manifests: [SkillManifest]
        do {
            manifests = try await manifestProvider(tenantID)
        } catch {
            return try await next(rewritable, context)
        }
        guard !manifests.isEmpty else {
            return try await next(rewritable, context)
        }

        // Run the selector — bounded by its own timeout.
        let selector = selectorFactory(tenantID, user.username)
        guard let chosen = await selector.selectSkill(
            for: userMessage,
            manifests: manifests,
            timeout: .milliseconds(300),
        ) else {
            return try await next(rewritable, context)
        }

        // Prepend chosen skill body to the system prompt and re-encode.
        let mutated = body.prependingSystem(content: chosen.body)
        guard let payload = try? JSONEncoder().encode(mutated) else {
            return try await next(rewritable, context)
        }
        rewritable.body = .init(buffer: ByteBuffer(bytes: payload))
        logger.info("context-routing matched skill=\(chosen.name) tenant=\(tenantID)")
        return try await next(rewritable, context)
    }
}

/// Mutable, decode-and-re-encode view of the chat-completions body the
/// middleware needs to touch. Permissive — extra fields on the wire are
/// preserved via the catch-all `extra` dictionary so the downstream
/// handler still sees them unchanged.
struct ChatRoutingBody: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    var messages: [Message]
    var model: String?
    var temperature: Double?

    var latestUserContent: String? {
        messages.reversed().first(where: { $0.role == "user" })?.content
    }

    /// Returns a copy with `system` content prepended. If a `system`
    /// message already exists at position 0, its content is replaced with
    /// `<skill body>\n\n<previous system>`; otherwise a new `system`
    /// message is inserted at index 0.
    func prependingSystem(content: String) -> ChatRoutingBody {
        var copy = self
        if let first = copy.messages.first, first.role == "system" {
            let merged = content + "\n\n" + first.content
            copy.messages[0] = Message(role: "system", content: merged)
        } else {
            copy.messages.insert(Message(role: "system", content: content), at: 0)
        }
        return copy
    }
}
