import Foundation
import Logging

/// HER-240a — abstraction for the side of `XaiOAuthService` that has to talk
/// to a long-running `hermes auth add xai-oauth --no-browser` process inside
/// a tenant's Hermes container.
///
/// The CLI prints a one-time `Authorize at: <URL>` line on stdout, then
/// blocks on a local TCP listener at `127.0.0.1:56121` (inside the
/// container) until xAI redirects there with `?code=…&state=…`. The
/// process exits 0 once it has exchanged the code for a token and written
/// `auth.json`.
///
/// The protocol splits the two phases so the service can be tested in
/// isolation. A live implementation drives the real CLI; a stub is used in
/// unit tests.
protocol XaiOAuthBackend: Sendable {
    /// Spawn the CLI and return the authorize URL it prints. Implementations
    /// must keep the subprocess running so its loopback listener stays open
    /// until `submitCallback` is invoked.
    func requestAuthorizeURL(handle: HermesContainerHandle, sessionID: String) async throws -> String

    /// Forward the captured callback URL (with `code` + `state`) to the
    /// container's loopback listener and wait for the CLI subprocess to
    /// exit. Returns `true` on a clean (exit code 0) completion.
    func submitCallback(
        handle: HermesContainerHandle,
        sessionID: String,
        callbackURL: String,
    ) async throws -> Bool

    /// Best-effort cancel for an in-flight session. Idempotent.
    func cancel(sessionID: String) async

    /// Run `hermes auth remove xai-oauth` inside the container. Returns
    /// `true` on success. Used when the user disconnects from iOS.
    func revoke(handle: HermesContainerHandle) async throws -> Bool
}

/// Live implementation that drives the real `docker exec` CLI flow.
///
/// **HER-240b TODO:** the bidirectional stdin/stdout streaming required to
/// (a) tail the spawned `hermes auth add` for its one-time `Authorize at:`
/// line and (b) keep the subprocess alive across the iOS → server round
/// trip is intentionally deferred. This skeleton exists so the route
/// surface, DTOs, and service composition can ship and be wired against
/// the iOS client in HER-240b. The first production user flow will land
/// alongside an integration test against a real Hermes container.
struct LiveXaiOAuthBackend: XaiOAuthBackend {
    private let docker: any DockerExec
    private let logger: Logger

    init(docker: any DockerExec, logger: Logger) {
        self.docker = docker
        self.logger = logger
    }

    func requestAuthorizeURL(handle: HermesContainerHandle, sessionID _: String) async throws -> String {
        logger.warning("LiveXaiOAuthBackend.requestAuthorizeURL not yet implemented", metadata: [
            "container": "\(handle.containerName)",
        ])
        throw XaiOAuthError.notYetImplemented
    }

    func submitCallback(
        handle: HermesContainerHandle,
        sessionID _: String,
        callbackURL _: String,
    ) async throws -> Bool {
        logger.warning("LiveXaiOAuthBackend.submitCallback not yet implemented", metadata: [
            "container": "\(handle.containerName)",
        ])
        throw XaiOAuthError.notYetImplemented
    }

    func cancel(sessionID _: String) async {}

    func revoke(handle: HermesContainerHandle) async throws -> Bool {
        let result = try await docker.exec(
            container: handle.containerName,
            command: ["hermes", "auth", "remove", "xai-oauth"],
        )
        return result.ok
    }
}

enum XaiOAuthError: Error, Equatable {
    case notYetImplemented
    case sessionNotFound
    case authorizeURLMissingFromStdout
    case callbackForwardFailed(stderr: String)
    case backendFailed(reason: String)
}
