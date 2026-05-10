import Hummingbird

/// Shared-secret admin gate. Compares the `X-Admin-Token` request header
/// (constant-time) against the configured token. Rejects all requests
/// when the token is empty so a misconfigured prod can't accidentally
/// expose admin routes.
///
/// Replace with real RBAC (User.role + JWT claim) before letting any
/// non-operator near the system.
struct AdminTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let expectedToken: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard !expectedToken.isEmpty else {
            throw HTTPError(.notFound, message: "admin disabled")
        }
        let header = request.headers[.init("x-admin-token")!]
        guard let presented = header,
              Self.constantTimeEquals(presented, expectedToken)
        else {
            throw HTTPError(.unauthorized, message: "admin token invalid")
        }
        return try await next(request, context)
    }

    /// Avoid early-exit timing leak when comparing tokens.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}
