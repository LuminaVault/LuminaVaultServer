import Foundation
import Hummingbird
import Logging

/// HER-217 — resolves the per-tenant Hermes endpoint once per request
/// and stashes the `Resolution` on `AppRequestContext.hermesResolution`.
///
/// Honours `HermesEndpointResolver`'s documented contract: agent loops
/// (memory tool calls, memo generator, KB compile, health correlation)
/// fire multiple chat requests per HTTP request, and each must NOT
/// round-trip to Postgres + KDF + AES-GCM. Cache once, re-use across
/// the entire request.
///
/// Apply AFTER `JWTAuthenticator` (the resolver needs the tenant ID
/// from the hydrated identity). When the upstream resolver throws —
/// SSRF rejection on revalidation, decrypt failure — the middleware
/// surfaces a 502 with a stable error code so the iOS client can show
/// "Your Hermes gateway is unreachable" without parsing free text.
struct HermesResolutionMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    let resolver: HermesEndpointResolver
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
            // No identity — let downstream routes return 401 via their own
            // `requireIdentity()` calls. Skip resolution to keep the middleware
            // composable on mixed auth/unauth router groups.
            return try await next(request, context)
        }

        let resolution: HermesEndpointResolver.Resolution
        do {
            resolution = try await resolver.resolve(tenantID: tenantID)
        } catch let err as HermesEndpointResolver.ResolutionError {
            logger.warning(
                "hermes endpoint resolution failed",
                metadata: [
                    "tenant": .string(tenantID.uuidString),
                    "error": .string(String(describing: err)),
                ],
            )
            throw HTTPError(
                .badGateway,
                message: "hermes_unreachable",
            )
        }

        var ctx = context
        ctx.hermesResolution = resolution
        return try await next(request, ctx)
    }
}
