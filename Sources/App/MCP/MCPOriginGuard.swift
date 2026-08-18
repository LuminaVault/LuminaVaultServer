import Hummingbird
import Logging

/// Rejects requests that carry a browser `Origin` LuminaVault does not
/// allow. A real MCP client sends no Origin; a page on the open web
/// must not be able to drive `/v1/mcp` with the user's cookies or a
/// leaked header.
///
/// Empty `allowedOrigins` (the default) means no browser origin is
/// accepted.
struct MCPOriginGuard: RouterMiddleware {
    typealias Context = AppRequestContext

    let allowedOrigins: Set<String>
    let logger: Logger

    init(allowedOrigins: [String] = [], logger: Logger) {
        self.allowedOrigins = Set(
            allowedOrigins
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        self.logger = logger
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if let origin = request.headers[.origin], !origin.isEmpty {
            if !allowedOrigins.contains(origin.lowercased()) {
                logger.warning(
                    "mcp request rejected: unrecognised origin",
                    metadata: ["origin": .string(origin)]
                )
                throw HTTPError(.forbidden, message: "forbidden")
            }
        }
        return try await next(request, context)
    }
}
