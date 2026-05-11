import FluentKit
import Hummingbird
import HummingbirdAuth
import HummingbirdFluent
import JWTKit

/// Verifies the request's `Authorization: Bearer <jwt>` and hydrates the User
/// identity onto the request context. Returns `nil` (not authenticated) if the
/// header is missing/malformed or the token fails verification — protected
/// routes use `context.requireIdentity()` to surface 401 to clients.
struct JWTAuthenticator: AuthenticatorMiddleware {
    typealias Context = AppRequestContext

    let jwtKeys: JWTKeyCollection
    let fluent: Fluent

    func authenticate(request: Request, context _: Context) async throws -> User? {
        guard let header = request.headers[.authorization] else { return nil }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return nil }
        let token = String(header.dropFirst(prefix.count))

        let payload: SessionToken
        do {
            payload = try await jwtKeys.verify(token, as: SessionToken.self)
        } catch {
            return nil
        }
        guard let userID = payload.userID else { return nil }
        return try await User.find(userID, on: fluent.db())
    }
}
