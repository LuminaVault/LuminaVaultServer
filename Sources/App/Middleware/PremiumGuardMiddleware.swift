import Foundation
import Hummingbird
import Logging

/// HER-240c — gates Grok routes on `User.tier`. Returns HTTP 402
/// `Payment Required` with a stable `requiresXaiConnect: true` body so the
/// iOS client can route the user back to the Linked Accounts pane without
/// parsing prose. Applies AFTER `JWTAuthenticator` (needs hydrated identity).
///
/// The default `allowed` set matches the existing `users_tier_check`
/// constraint values that imply an active paid subscription: `pro` and
/// `ultimate`. `tier_override` short-circuits the check so ops can grant
/// access manually without flipping a billing row.
struct PremiumGuardMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    let allowed: Set<String>
    let logger: Logger

    init(allowed: Set<String> = ["pro", "ultimate"], logger: Logger) {
        self.allowed = allowed
        self.logger = logger
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let user = try context.requireIdentity()
        let effective = user.tierOverride != "none" ? user.tierOverride : user.tier
        if allowed.contains(effective) {
            return try await next(request, context)
        }
        logger.info("premium guard rejected request", metadata: [
            "userID": "\(user.id?.uuidString ?? "?")",
            "tier": "\(effective)",
            "path": "\(request.uri.path)",
        ])
        let body = #"{"error":"premium_required","tier":"\#(effective)","requiresXaiConnect":true}"#
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: .init(code: 402, reasonPhrase: "Payment Required"),
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }
}
