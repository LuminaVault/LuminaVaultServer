import Hummingbird

/// Shared-secret gate for internal sidecar callbacks. Accepts either the
/// explicit sidecar header or a bearer Authorization header so callers can use
/// the same token shape as the sidecar control plane.
struct SidecarTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let expectedToken: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard !expectedToken.isEmpty else {
            throw HTTPError(.notFound, message: "sidecar webhook disabled")
        }
        guard let presented = Self.presentedToken(from: request),
              Self.constantTimeEquals(presented, expectedToken)
        else {
            throw HTTPError(.unauthorized, message: "sidecar token invalid")
        }
        return try await next(request, context)
    }

    private static func presentedToken(from request: Request) -> String? {
        if let token = request.headers[.init("x-lumina-sidecar-token")!] {
            return token
        }
        guard let authorization = request.headers[.authorization] else {
            return nil
        }
        if authorization.hasPrefix("Bearer ") {
            return String(authorization.dropFirst("Bearer ".count))
        }
        return authorization
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
