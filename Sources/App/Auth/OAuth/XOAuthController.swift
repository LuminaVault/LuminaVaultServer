import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

struct XExchangeRequest: Codable {
    let accessToken: String
}

/// X (Twitter) OAuth 2.0 + PKCE. iOS does the redirect + PKCE flow client
/// side and forwards the bearer access_token. Server verifies by hitting
/// `/2/users/me` and runs the shared upsert. Falls outside the existing
/// OIDC `OAuthProvider` protocol because X tokens aren't id_tokens.
struct XOAuthController {
    let authService: any AuthService
    let xClient: any XAPIClient
    let logger: Logger

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("/oauth/x/exchange", use: exchange)
    }

    @Sendable
    func exchange(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: XExchangeRequest.self, context: ctx)
        guard !body.accessToken.isEmpty else {
            throw HTTPError(.badRequest, message: "accessToken required")
        }
        let xUser = try await xClient.fetchMe(accessToken: body.accessToken)
        // X may not return an email (depends on app permission tier). Fall
        // back to a placeholder so downstream tenant code (which assumes a
        // unique email) doesn't break.
        let email = xUser.email?.lowercased() ?? "\(xUser.id)@x.luminavault.local"
        let user = try await authService.upsertOAuthUser(
            provider: "x",
            providerUserID: xUser.id,
            email: email,
            emailVerified: xUser.email != nil,
        )
        logger.info("x oauth: linked id=\(xUser.id) username=\(xUser.username)")
        return try await authService.issueTokens(for: user)
    }
}
