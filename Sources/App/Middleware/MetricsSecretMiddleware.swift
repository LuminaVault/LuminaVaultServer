import Hummingbird

/// Shared-secret gate for the operator-only `/internal/metrics` endpoint that
/// facorreia.com/apps reads. Bearer token only, compared in constant time.
/// An empty configured secret disables the route (404) so a misconfigured
/// deployment never exposes it unauthenticated.
struct MetricsSecretMiddleware<Context: RequestContext>: RouterMiddleware {
    let expectedSecret: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard !expectedSecret.isEmpty else {
            throw HTTPError(.notFound, message: "metrics disabled")
        }
        guard let presented = Self.bearerToken(from: request),
              Self.constantTimeEquals(presented, expectedSecret)
        else {
            throw HTTPError(.unauthorized, message: "metrics secret invalid")
        }
        return try await next(request, context)
    }

    private static func bearerToken(from request: Request) -> String? {
        guard let authorization = request.headers[.authorization],
              authorization.hasPrefix("Bearer ")
        else {
            return nil
        }
        return String(authorization.dropFirst("Bearer ".count))
    }

    /// Avoid early-exit timing leaks when comparing shared secrets.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}
