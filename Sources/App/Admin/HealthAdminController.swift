import Foundation
import Hummingbird

extension HealthCorrelationSweepSummary: ResponseEncodable {}

/// HER-146 single-user correlation response. Flat-serialised so a cron
/// driver can grep the JSON for `status` without enum-case walking.
struct HealthCorrelationRunResponse: Codable, ResponseEncodable {
    /// `"saved"` | `"skipped_insufficient_history"` | `"skipped_already_ran"` |
    /// `"skipped_no_recent_events"` | `"skipped_no_synthesis"`
    let status: String
    let memoryId: UUID?

    init(_ outcome: HealthCorrelationOutcome) {
        switch outcome {
        case let .saved(id):
            status = "saved"
            memoryId = id
        case .skippedInsufficientHistory:
            status = "skipped_insufficient_history"
            memoryId = nil
        case .skippedAlreadyRanThisWeek:
            status = "skipped_already_ran"
            memoryId = nil
        case .skippedNoRecentEvents:
            status = "skipped_no_recent_events"
            memoryId = nil
        case .skippedNoSynthesis:
            status = "skipped_no_synthesis"
            memoryId = nil
        }
    }
}

/// HER-146 — admin endpoints for the Apple Health correlation job.
/// Mounted at `/v1/admin/health` behind `AdminTokenMiddleware`.
/// Host cron drives this nightly via:
///
///   curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/health/correlate
///
/// Per-user errors do not abort the sweep; they accumulate in the
/// `failures[]` array of the response body.
struct HealthAdminController {
    let job: HealthCorrelationJob

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/correlate", use: correlateAll)
        router.post("/correlate/:userID", use: correlateOne)
    }

    @Sendable
    func correlateAll(_: Request, ctx _: AppRequestContext) async throws -> HealthCorrelationSweepSummary {
        try await job.runForAllUsers()
    }

    @Sendable
    func correlateOne(_: Request, ctx: AppRequestContext) async throws -> HealthCorrelationRunResponse {
        guard let raw = ctx.parameters.get("userID"), let userID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid userID")
        }
        let outcome = try await job.runForUser(id: userID)
        return HealthCorrelationRunResponse(outcome)
    }
}
