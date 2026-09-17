import FluentKit
import Hummingbird
import HummingbirdFluent

/// `GET /internal/metrics` → `{"users": N}` for the portfolio board at
/// facorreia.com/apps. Guarded by `MetricsSecretMiddleware` (METRICS_SECRET);
/// mounted at the root, outside `/v1`, next to `/health`.
struct InternalMetricsController {
    struct MetricsResponse: Codable, ResponseEncodable {
        let users: Int
    }

    let fluent: Fluent
    let expectedSecret: String

    func addRoutes(to router: Router<AppRequestContext>) {
        router.group("/internal")
            .add(middleware: MetricsSecretMiddleware<AppRequestContext>(expectedSecret: expectedSecret))
            .get("metrics", use: metrics)
    }

    @Sendable
    func metrics(_: Request, context _: AppRequestContext) async throws -> MetricsResponse {
        let users = try await User.query(on: fluent.db()).count()
        return MetricsResponse(users: users)
    }
}
