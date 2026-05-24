import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// HER-273 — resolve the active Hermes persona from the
/// `X-Hermes-Profile: <slug>` request header and stamp the outbound
/// `X-Hermes-Session-Key` value on the request context.
///
/// Behaviour:
///   1. Header absent → fall back to the tenant's default
///      `UserHermesProfile`. If none exists, lazy-create a `"default"`
///      persona via `HermesProfileService.ensureDefaultPersona`.
///   2. Header present → look up the row by slug. Unknown slug fails
///      404 with `unknown_profile` so the iOS client surfaces a clean
///      "profile not found" instead of degrading silently.
///   3. Compose `<hermesProfileID>:<slug>` and stash on
///      `ctx.activeHermesSessionKey`. Downstream chat / memory
///      services read this and forward it as the Hermes session
///      header (cutover in a follow-up — see file-level comment on
///      `HermesLLMService`).
///
/// Apply AFTER `JWTAuthenticator` (needs tenant ID) and AFTER
/// `HermesResolutionMiddleware` (the resolution carries the underlying
/// Hermes profile ID we splice into the session key).
struct HermesProfileMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    enum ErrorCode: String {
        case unknownProfile = "unknown_profile"
        case hermesProfileMissing = "hermes_profile_missing"
    }

    let fluent: Fluent
    let profiles: HermesProfileService
    let logger: Logger

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        let tenantID: UUID
        do {
            tenantID = try context.requireTenantID()
        } catch {
            return try await next(request, context)
        }

        let user = try context.requireIdentity()
        // The 1:1 Hermes container slot — needed to compose the
        // session-key prefix. Lazy-provisioned at signup; degraded
        // tenants fall through to a stub key so chat still routes,
        // but personas can't be isolated meaningfully.
        let hermesProfile = try await profiles.ensureSoftAndFind(for: user, logger: logger)

        let requestedSlug = request.headers[.init("x-hermes-profile")!]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var ctx = context
        let resolved: UserHermesProfile
        if let slug = requestedSlug, !slug.isEmpty {
            guard let row = try await UserHermesProfile.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$slug == slug)
                .first()
            else {
                throw HTTPError(.notFound, message: ErrorCode.unknownProfile.rawValue)
            }
            resolved = row
        } else {
            resolved = try await profiles.ensureDefaultPersona(tenantID: tenantID)
        }

        ctx.activeProfileSlug = resolved.slug
        if let hermesProfile {
            ctx.activeHermesSessionKey = "\(hermesProfile.hermesProfileID):\(resolved.slug)"
        } else {
            // Hermes container not yet ready — best-effort key so the
            // chat path still has something stable to thread. Hermes
            // treats unknown session keys as a fresh session.
            ctx.activeHermesSessionKey = "pending-\(tenantID.uuidString):\(resolved.slug)"
            logger.debug("hermes profile not ready for tenant \(tenantID); using pending session key")
        }
        return try await next(request, ctx)
    }
}
