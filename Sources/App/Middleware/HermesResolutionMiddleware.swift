import Foundation
import Hummingbird
import Logging

/// HER-217 / HER-223 — resolves the per-tenant Hermes endpoint once per
/// request and propagates it two ways:
///
///   1. Stashes the `Resolution` on `AppRequestContext.hermesResolution`
///      so handlers that need direct access can read it.
///   2. Binds `LLMRoutingContext.currentResolution` as a `@TaskLocal` for
///      the lifetime of the downstream call. `HermesGatewayAdapter` reads
///      this inside `chatCompletionsWithMetadata` and dispatches against
///      the user's hosted gateway when `isUserOverride == true`.
///
/// Honours `HermesEndpointResolver`'s documented contract: agent loops
/// (memory tool calls, memo generator, KB compile, health correlation)
/// fire multiple chat requests per HTTP request, and each must NOT
/// round-trip to Postgres + KDF + AES-GCM. The resolver runs once; the
/// task-local replays for every downstream dispatch.
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
        next: (Request, Context) async throws -> Response
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
                ]
            )
            // Still 502 and still `hermes_unreachable` on the wire, but as a
            // `{code, message}` envelope so the client can show the reason
            // instead of the bare token. This never dials the gateway — it is
            // a *resolution* failure — and it fires for the whole route group,
            // so an unhelpful message here made listing conversations look as
            // broken as sending one.
            throw UpstreamErrorResponse(
                reasonCode: "hermes_unreachable",
                userMessage: Self.message(for: err)
            )
        }

        var ctx = context
        ctx.hermesResolution = resolution
        return try await LLMRoutingContext.$currentResolution.withValue(resolution) {
            try await next(request, ctx)
        }
    }

    /// Each resolution failure has a different fix, and the user is the only
    /// one who can apply any of them.
    static func message(for error: HermesEndpointResolver.ResolutionError) -> String {
        switch error {
        case let .ssrfRejected(reason):
            "Your Hermes address could not be used (\(reason)). Check the URL in Settings — a hostname that only resolves on your own network will not resolve from here; the tailnet IP does."
        case .decryptFailed:
            "Your saved Hermes credentials could not be read. Re-enter the auth header in Settings."
        case .malformedRow:
            "Your Hermes configuration is incomplete. Re-save it in Settings."
        }
    }
}
