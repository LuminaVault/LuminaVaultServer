import Hummingbird
import HummingbirdAuth
import HummingbirdFluent
import JWTKit

/// Accepts either a session JWT or an `lv_` agent-connection token.
/// Agent tokens are checked first (cheap prefix); anything else falls
/// through to the existing JWT verifier. Both hydrate `User` onto the
/// request so `/v1/mcp` keeps resolving the vault from identity.
struct MCPAuthenticator: AuthenticatorMiddleware {
    typealias Context = AppRequestContext

    let jwt: JWTAuthenticator
    let agents: AgentConnectionService

    func authenticate(request: Request, context: Context) async throws -> User? {
        guard let header = request.headers[.authorization] else { return nil }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return nil }
        let token = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }

        if token.hasPrefix(AgentConnectionService.tokenPrefix) {
            return try await agents.authenticate(token: token)
        }
        return try await jwt.authenticate(request: request, context: context)
    }
}
