import Foundation
import Hummingbird
import LuminaVaultShared

extension SuggestionsResponse: ResponseEncodable {}

/// GET /v1/me/suggestions — surfaces context-aware natural-language query
/// prompts above the "Ask Lumina" input bar on the iOS client.
///
/// **Scaffold:** returns a fixed list. HER-37a will replace this with
/// per-user suggestions derived from recent compiles, active Spaces, and
/// SOUL.md tone.
struct SuggestionsController {
    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/suggestions", use: list)
    }

    @Sendable
    func list(_: Request, ctx _: AppRequestContext) async throws -> SuggestionsResponse {
        SuggestionsResponse(suggestions: Self.defaults)
    }

    static let defaults: [String] = [
        "What patterns do I have in my Stocks space lately?",
        "Summarize everything I learned about sleep this month",
        "Connect my recent travel notes with my health data",
        "What ideas have I had about AI agents in the last 3 months?",
        "Where did I leave off on my Hermes project?",
    ]
}
