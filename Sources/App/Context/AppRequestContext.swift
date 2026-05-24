import Foundation
import Hummingbird
import HummingbirdAuth
import HummingbirdWebSocket

struct AppRequestContext: AuthRequestContext, RequestContext, WebSocketRequestContext {
    typealias Identity = User
    var coreContext: CoreRequestContextStorage
    var identity: User?
    let webSocket: WebSocketHandlerReference<Self>
    /// HER-217 — set by `HermesResolutionMiddleware`. Downstream chat
    /// services read this instead of round-tripping to Postgres + KDF
    /// + AES-GCM on every tool call inside an agent loop.
    var hermesResolution: HermesEndpointResolver.Resolution?
    /// HER-273 — set by `HermesProfileMiddleware`. The active user
    /// persona's slug (e.g. `stocks`, `news`) resolved from the
    /// `X-Hermes-Profile` request header, or the user's default
    /// profile if the header is absent.
    var activeProfileSlug: String?
    /// HER-273 — composed session key forwarded to the Hermes
    /// container as `X-Hermes-Session-Key`. Shape:
    /// `<hermesProfileID>:<slug>`. Lets a single user run multiple
    /// memory-isolated personas through the same Hermes container.
    var activeHermesSessionKey: String?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        identity = nil
        webSocket = .init()
        hermesResolution = nil
        activeProfileSlug = nil
        activeHermesSessionKey = nil
    }

    func requireTenantID() throws -> UUID {
        let user = try requireIdentity()
        return try user.requireID()
    }
}
