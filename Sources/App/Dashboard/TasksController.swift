import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension TaskListResponse: @retroactive ResponseEncodable {}

/// `GET /v1/tasks` — list active/queued/completed/failed server-side
/// operations for the authenticated tenant.
///
/// Command Center / HER-246: backed by `ActiveTasksQuery` (workflow runs +
/// gateway apply jobs). Terminal history is not fully unified yet; clients
/// primarily filter `state=running|queued` for the live jobs deck.
struct TasksController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    private static let maxLimit = ActiveTasksQuery.maxLimit
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> TaskListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let state = Self.parseState(req)
        let limit = Self.parseLimit(req)
        let tasks = try await ActiveTasksQuery.list(
            tenantID: tenantID,
            db: fluent.db(),
            state: state,
            limit: limit
        )
        return TaskListResponse(tasks: tasks, nextCursor: nil)
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
