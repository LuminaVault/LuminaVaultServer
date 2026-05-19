import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension TaskListResponse: ResponseEncodable {}

/// `GET /v1/tasks` — list active/queued/completed/failed server-side
/// operations for the authenticated tenant.
///
/// HER-244: initial implementation always returns an empty list. The
/// real job-tracking surface ships under HER-246 with persistence and
/// WebSocket push updates.
struct TasksController {
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> TaskListResponse {
        _ = try ctx.requireIdentity()
        _ = Self.parseState(req)
        _ = Self.parseLimit(req)
        return TaskListResponse(tasks: [], nextCursor: nil)
    }

    private static func parseState(_ req: Request) -> TaskState? {
        guard let raw = req.uri.queryParameters["state"] else { return nil }
        return TaskState(rawValue: String(raw))
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }
}
