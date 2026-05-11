import Foundation
import Hummingbird
import Logging

/// Hummingbird middleware that — when the requesting user has opted in
/// (`users.context_routing=true`) — asks a `capability=low` model which
/// (if any) of their enabled skills' `description` matches the inbound
/// chat message, and prepends the selected skill's body to the system
/// prompt. Selection is capped at one skill per message to prevent
/// cascading prompt bloat (HER-172 acceptance).
///
/// ## Cost guard
/// - Default **OFF**. Pro-tier opt-in only.
/// - Free users never get it: the extra `low`-tier call per message
///   would chip away at their daily Mtok cap.
/// - Selection latency budget: < 300ms p95 (Gemini Flash route).
///
/// HER-148 scaffold: no-op middleware that passes through to `next`.
/// Real selection logic lands in HER-172.
struct ContextRouterMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    private let catalog: SkillCatalog
    private let logger: Logger

    init(catalog: SkillCatalog, logger: Logger) {
        self.catalog = catalog
        self.logger = logger
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        // HER-172: read user.context_routing, select 1 skill via low-cap model,
        // mutate request body to prepend skill.body to system prompt.
        try await next(request, context)
    }
}
