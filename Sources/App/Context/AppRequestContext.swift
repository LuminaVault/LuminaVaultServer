import Foundation
import Hummingbird
import HummingbirdAuth

struct AppRequestContext: AuthRequestContext, RequestContext {
    typealias Identity = User
    var coreContext: CoreRequestContextStorage
    var identity: User?

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.identity = nil
    }

    func requireTenantID() throws -> UUID {
        let user = try requireIdentity()
        return try user.requireID()
    }
}

