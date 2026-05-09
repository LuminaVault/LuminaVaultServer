import HummingbirdFluent
import JWTKit

/// Typed bundle of long-lived services injected into routes/repositories.
/// Hummingbird's Application has no `app.storage` key system — pass this
/// struct explicitly into router builders and controllers.
struct ServiceContainer: Sendable {
    let fluent: Fluent
    let jwtKeys: JWTKeyCollection
    let jwtKID: JWKIdentifier
}
