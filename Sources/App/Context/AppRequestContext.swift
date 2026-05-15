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

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        identity = nil
        webSocket = .init()
        hermesResolution = nil
    }

    func requireTenantID() throws -> UUID {
        let user = try requireIdentity()
        return try user.requireID()
    }
}
