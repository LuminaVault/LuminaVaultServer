import HummingbirdFluent
import JWTKit
import Logging

/// Typed bundle of long-lived services injected into routes/repositories.
/// Hummingbird's Application has no `app.storage` key system — pass this
/// struct explicitly into router builders and controllers.
struct ServiceContainer: Sendable {
    let fluent: Fluent
    let jwtKeys: JWTKeyCollection
    let jwtKID: JWKIdentifier
    let logLevel: Logger.Level
    /// OAuth provider client IDs (audience claim). Empty string disables that provider.
    let appleClientID: String
    let googleClientID: String
    /// Filesystem root for `tenants/<id>/raw/` Hermes/vault directories.
    let vaultRootPath: String
    /// Selects which `HermesGateway` impl to use:
    ///   `filesystem` (default) — write profile.json into the shared volume.
    ///   `logging`              — dev stub; logs and returns hermes-<username>.
    ///   `http` / `docker_exec` — reserved for future impls; throw on use.
    let hermesGatewayKind: String
    /// Base URL of the Hermes OpenAI-compatible gateway. Inside the docker
    /// network the service hostname is `hermes` (compose service name).
    let hermesGatewayURL: String
    /// Filesystem root for Hermes profile data (the host `./data/hermes`
    /// mount; visible to Hummingbird as `/app/data/hermes`).
    let hermesDataRoot: String
    /// Default model name when chat requests don't specify one. Verify via
    /// `GET http://hermes:8642/v1/models` against the running container.
    let hermesDefaultModel: String
    /// WebAuthn / passkeys.
    let webAuthnEnabled: Bool
    let webAuthnRelyingPartyID: String
    let webAuthnRelyingPartyName: String
    let webAuthnRelyingPartyOrigin: String
    /// APNS example notification support.
    let apnsEnabled: Bool
    let apnsBundleID: String
    let apnsTeamID: String
    let apnsKeyID: String
    let apnsPrivateKeyPath: String
    let apnsEnvironment: String
    let apnsDeviceToken: String
}
