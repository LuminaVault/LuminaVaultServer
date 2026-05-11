import Hummingbird

/// Rejects any cross-origin request whose `Origin` header is not on the
/// allow-list with `403`. Requests without an `Origin` header (same-origin
/// HTTP, server-to-server) are passed through unchanged.
///
/// Pair this with `CORSMiddleware(allowOrigin: .originBased)` downstream:
/// allowed origins reach CORSMiddleware and get echoed back; disallowed
/// origins never make it that far so the browser receives no
/// `Access-Control-Allow-Origin` header and blocks the response.
struct AllowedOriginsMiddleware<Context: RequestContext>: RouterMiddleware {
    let allowed: Set<String>

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        if let origin = request.headers[.origin], !allowed.contains(origin) {
            throw HTTPError(.forbidden, message: "origin not allowed")
        }
        return try await next(request, context)
    }
}
