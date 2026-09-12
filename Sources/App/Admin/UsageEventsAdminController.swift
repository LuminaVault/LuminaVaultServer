import Hummingbird

extension UsageEventsRetentionService.Summary: ResponseEncodable {}

/// Admin-gated retention sweep for `usage_events`.
///
///   curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/usage-events/prune
///
/// A route rather than an in-process timer, matching `MemoryAdminController`:
/// the host cron already owns periodic maintenance here, and a scheduler
/// inside the app would run the sweep once per replica.
///
/// Returns the policy alongside the result, so a cron that finds `enabled:
/// false` reports a configuration problem instead of silently doing nothing
/// every night.
struct UsageEventsAdminController {
    let service: UsageEventsRetentionService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/prune", use: prune)
    }

    @Sendable
    func prune(_: Request, ctx _: AppRequestContext) async throws -> UsageEventsRetentionService.Summary {
        try await service.sweep()
    }
}
