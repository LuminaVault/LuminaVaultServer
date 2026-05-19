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

/// HER-240c — live implementation that drives `hermes auth add xai-oauth
/// --no-browser` inside each tenant's Hermes container.
///
/// Flow:
///   1. `requestAuthorizeURL` spawns a streaming `docker exec` of the CLI,
///      tails stdout until it sees the one-time `Authorize at: <URL>`
///      line, parks the still-running process handle in the
///      `XaiOAuthProcessRegistry`, and returns the URL. The CLI keeps
///      its loopback listener open while it waits for the callback.
///   2. `submitCallback` pulls the parked handle, runs a second
///      `docker exec curl` inside the same container to POST the
///      captured callback URL to `http://127.0.0.1:56121/callback?...`,
///      then awaits the original CLI's exit code.
///   3. `cancel` terminates a parked subprocess without forwarding any
///      callback — used when the user dismisses the iOS sheet.
///   4. `revoke` runs `hermes auth remove xai-oauth` (no streaming
///      needed — short-lived command).
///
/// Authorize-URL detection is line-prefix-based: the Hermes CLI prints
/// `Authorize at: https://accounts.x.ai/...` per its docs. We treat
/// anything matching that exact prefix as the URL line; alternate phrasing
/// (`Visit:` etc.) is tolerated via `authorizeURLLinePrefixes` so a future
/// Hermes wording change doesn't immediately break us.
struct LiveXaiOAuthBackend: XaiOAuthBackend {
    private let docker: any DockerExec
    private let registry: XaiOAuthProcessRegistry
    private let logger: Logger
    /// Inside-container path to the hermes CLI. Defaults to the Python
    /// venv install location documented in the Hermes Agent docker
    /// guide; overridable for custom images.
    private let hermesBinaryPath: String
    /// Inside-container loopback URL the CLI listens on. xAI requires the
    /// exact host:port:path documented; reading it from config so a
    /// future Hermes default change doesn't require a redeploy.
    private let loopbackURL: String
    /// Max wall-clock seconds to wait for the `Authorize at:` line.
    /// Hermes prints it within milliseconds of process start; a long
    /// timeout here masks docker spawn failures.
    private let startTimeoutSeconds: Int
    /// Max wall-clock seconds to wait for the CLI to exit after we
    /// forward the callback. Hermes finishes the OAuth exchange in
    /// well under a second on the happy path; longer waits indicate a
    /// stuck token-exchange call to xAI.
    private let completeTimeoutSeconds: Int

    private static let authorizeURLLinePrefixes = [
        "Authorize at:",
        "Visit:",
        "Open this URL:",
    ]

    init(
        docker: any DockerExec,
        registry: XaiOAuthProcessRegistry,
        logger: Logger,
        hermesBinaryPath: String = "/opt/hermes/.venv/bin/hermes",
        loopbackURL: String = "http://127.0.0.1:56121/callback",
        startTimeoutSeconds: Int = 30,
        completeTimeoutSeconds: Int = 60,
    ) {
        self.docker = docker
        self.registry = registry
        self.logger = logger
        self.hermesBinaryPath = hermesBinaryPath
        self.loopbackURL = loopbackURL
        self.startTimeoutSeconds = startTimeoutSeconds
        self.completeTimeoutSeconds = completeTimeoutSeconds
    }

    func requestAuthorizeURL(handle: HermesContainerHandle, sessionID: String) async throws -> String {
        let streaming = try await docker.execStreaming(
            container: handle.containerName,
            command: [hermesBinaryPath, "auth", "add", "xai-oauth", "--no-browser"],
        )

        let url = try await withTimeout(seconds: startTimeoutSeconds) {
            try await Self.consumeAuthorizeURL(from: streaming.lines)
        } onTimeout: {
            await streaming.cancel()
            throw XaiOAuthError.authorizeURLMissingFromStdout
        }

        await registry.put(sessionID: sessionID, handle: streaming)
        logger.info("xai-oauth authorize URL emitted", metadata: [
            "sessionID": "\(sessionID)",
            "container": "\(handle.containerName)",
        ])
        return url
    }

    func submitCallback(
        handle: HermesContainerHandle,
        sessionID: String,
        callbackURL: String,
    ) async throws -> Bool {
        guard let entry = await registry.take(sessionID: sessionID) else {
            throw XaiOAuthError.sessionNotFound
        }

        // Append `?` to loopback URL only if callbackURL doesn't already
        // have query bytes that should be forwarded as-is. Forward exactly
        // what xAI redirected to; the path matters less than `code` +
        // `state`.
        let forwardURL = Self.forwardURL(
            loopback: loopbackURL,
            captured: callbackURL,
        )

        let curlResult = try await docker.exec(
            container: handle.containerName,
            command: ["curl", "--silent", "--show-error", "--max-time", "10", forwardURL],
        )
        guard curlResult.ok else {
            await entry.handle.cancel()
            throw XaiOAuthError.callbackForwardFailed(stderr: curlResult.stderr)
        }

        let exitCode = try await withTimeout(seconds: completeTimeoutSeconds) {
            try await entry.handle.wait()
        } onTimeout: {
            await entry.handle.cancel()
            throw XaiOAuthError.backendFailed(reason: "hermes CLI did not exit within timeout")
        }
        logger.info("xai-oauth CLI exited", metadata: [
            "sessionID": "\(sessionID)",
            "exitCode": "\(exitCode)",
        ])
        return exitCode == 0
    }

    func cancel(sessionID: String) async {
        await registry.cancel(sessionID: sessionID)
    }

    func revoke(handle: HermesContainerHandle) async throws -> Bool {
        let result = try await docker.exec(
            container: handle.containerName,
            command: [hermesBinaryPath, "auth", "remove", "xai-oauth"],
        )
        return result.ok
    }

    // MARK: - Helpers

    /// Reads the streaming line iterator until one of the documented
    /// `Authorize at:` prefixes matches. Returns the URL portion. Lines
    /// that don't match are logged at trace but otherwise ignored —
    /// Hermes prints a banner + status messages before the URL.
    static func consumeAuthorizeURL(from lines: AsyncStream<String>) async throws -> String {
        for await line in lines {
            for prefix in authorizeURLLinePrefixes
                where line.hasPrefix(prefix) || line.contains(prefix) {
                let trimmed = line.replacingOccurrences(of: prefix, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            // Some Hermes builds print the URL on its own line right after
            // the banner; tolerate that by accepting any https:// xAI URL.
            if line.hasPrefix("https://accounts.x.ai/")
                || line.hasPrefix("https://x.ai/")
            {
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw XaiOAuthError.authorizeURLMissingFromStdout
    }

    /// Combines the inside-container loopback base with the query string
    /// the iOS app captured. Strips the captured URL's scheme/host so the
    /// container hits its own loopback regardless of what `redirect_uri`
    /// the iOS WKWebView saw.
    static func forwardURL(loopback: String, captured: String) -> String {
        guard let parsed = URLComponents(string: captured),
              let query = parsed.query
        else {
            return loopback
        }
        let separator = loopback.contains("?") ? "&" : "?"
        return loopback + separator + query
    }
}

enum XaiOAuthError: Error, Equatable {
    case notYetImplemented
    case sessionNotFound
    case authorizeURLMissingFromStdout
    case callbackForwardFailed(stderr: String)
    case backendFailed(reason: String)
}

/// Race the given operation against a timeout. The timeout closure runs
/// once if the deadline is reached and may throw; otherwise the operation's
/// result is returned.
private func withTimeout<R: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> R,
    onTimeout: @escaping @Sendable () async throws -> Void,
) async throws -> R {
    try await withThrowingTaskGroup(of: TimeoutOutcome<R>.self) { group in
        group.addTask {
            .completed(try await operation())
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            return .timedOut
        }
        guard let outcome = try await group.next() else {
            throw XaiOAuthError.backendFailed(reason: "timeout race produced no outcome")
        }
        group.cancelAll()
        switch outcome {
        case let .completed(value):
            return value
        case .timedOut:
            try await onTimeout()
            throw XaiOAuthError.backendFailed(reason: "operation timed out")
        }
    }
}

private enum TimeoutOutcome<R: Sendable>: Sendable {
    case completed(R)
    case timedOut
}
