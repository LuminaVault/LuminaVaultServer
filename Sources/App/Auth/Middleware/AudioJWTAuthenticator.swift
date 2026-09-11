import FluentKit
import Hummingbird
import HummingbirdAuth
import HummingbirdFluent
import JWTKit

/// Authenticator for the OpenAI-shaped `/v1/audio/*` routes.
///
/// Accepts two kinds of caller:
///
///  1. An ordinary user session (`scp == nil`) — so the iOS and web clients
///     can use these endpoints like any other.
///  2. A token scoped to `SessionToken.Scope.audio` — the long-lived
///     credential seeded into a tenant's Hermes container so its speech-to-text
///     client can reach us instead of a provider directly.
///
/// The second kind is refused everywhere else: `JWTAuthenticator` rejects any
/// token carrying a scope. That asymmetry is the whole security model, so the
/// two must be read together.
///
/// Scoped tokens are additionally checked against the tenant's
/// `hermesAudioTokenEpoch`. Revocation moves that timestamp forward rather
/// than tracking individual tokens: the container is recreated on every
/// gateway change anyway, so a fresh token is cheap and a leaked one is
/// short-lived.
struct AudioJWTAuthenticator: AuthenticatorMiddleware {
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

        // Only the audio scope (or no scope at all) belongs here. An unknown
        // scope is refused rather than ignored, so adding a future scope
        // cannot silently widen this route's access.
        switch payload.scp {
        case nil, .some(SessionToken.Scope.audio):
            break
        default:
            return nil
        }

        guard let userID = payload.userID else { return nil }
        guard let user = try await User.find(userID, on: fluent.db()) else { return nil }

        if payload.scp == SessionToken.Scope.audio,
           let epoch = user.hermesAudioTokenEpoch
        {
            // `iat` is absent on tokens minted before the claim existed; a
            // scoped token always carries one, so a missing `iat` here means
            // a malformed credential and is refused.
            guard let issuedAt = payload.issuedAt?.value, issuedAt > epoch else {
                return nil
            }
        }

        return user
    }
}
