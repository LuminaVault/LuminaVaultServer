import Foundation
import Hummingbird
import HummingbirdAuth
import HummingbirdWebSocket

struct AppRequestContext: AuthRequestContext, RequestContext, WebSocketRequestContext {
    typealias Identity = User
    var coreContext: CoreRequestContextStorage
    var identity: User?
    let webSocket: WebSocketHandlerReference<Self>

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        identity = nil
        webSocket = .init()
    }

    func requireTenantID() throws -> UUID {
        let user = try requireIdentity()
        return try user.requireID()
    }
}
