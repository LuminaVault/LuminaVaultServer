import Foundation
import Hummingbird
import JWTKit
import Logging

struct AccountDeleteRequest: Codable, Sendable {
    let password: String?
}

/// HER-92: account-management endpoints. Currently only `DELETE /v1/account`
/// (GDPR / CCPA right-to-erasure). Mount behind `JWTAuthenticator` so the
/// caller is already resolved to a `User`.
struct AccountController {
    let service: AccountDeletionService
    let jwtKeys: JWTKeyCollection

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.delete("", use: delete)
    }

    @Sendable
    func delete(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let body = try await Self.decodeBodyAllowingEmpty(req: req, ctx: ctx)
        let tokenIat = await Self.tokenIssuedAt(req: req, keys: jwtKeys)
        try await service.deleteAccount(
            user: user,
            password: body.password,
            tokenIssuedAt: tokenIat
        )
        return Response(status: .noContent)
    }

    /// Body is optional — `password` may be omitted when the JWT is fresh.
    /// Treat a missing/empty body as `AccountDeleteRequest(password: nil)`.
    private static func decodeBodyAllowingEmpty(
        req: Request, ctx: AppRequestContext
    ) async throws -> AccountDeleteRequest {
        do {
            return try await req.decode(as: AccountDeleteRequest.self, context: ctx)
        } catch {
            return AccountDeleteRequest(password: nil)
        }
    }

    /// Re-verifies the bearer token to lift the `iat` claim. JWTAuthenticator
    /// already verified the signature on the way in, so failures here are
    /// treated as "no iat available" (fresh-JWT path simply unavailable).
    private static func tokenIssuedAt(req: Request, keys: JWTKeyCollection) async -> Date? {
        guard let header = req.headers[.authorization], header.hasPrefix("Bearer ") else {
            return nil
        }
        let token = String(header.dropFirst("Bearer ".count))
        do {
            let payload = try await keys.verify(token, as: SessionToken.self)
            return payload.issuedAt?.value
        } catch {
            return nil
        }
    }
}
