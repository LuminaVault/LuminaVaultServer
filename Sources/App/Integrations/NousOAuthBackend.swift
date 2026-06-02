import Foundation
import Logging

/// Nous Subscription Integration — abstraction for the side of
/// `NousOAuthService` that drives a long-running `hermes auth add nous
/// --type oauth` process inside a tenant's Hermes container.
///
/// Nous Portal uses an OAuth **device-code** flow (confirmed against
/// hermes-agent.nousresearch.com docs). The CLI prints a verification URL +
/// a user-code, then **polls** the Nous token endpoint until the user
/// approves the device in their browser, writes the refresh token to
/// `~/.hermes/auth.json`, and exits 0. This differs from the xAI loopback
/// flow: there is no callback URL to forward, so `awaitCompletion` only has
/// to wait for the polling CLI to exit.
///
/// The protocol splits the two phases so the service can be tested in
/// isolation. A live implementation drives the real CLI; a stub is used in
/// unit tests.
protocol NousOAuthBackend: Sendable {
    /// Spawn the CLI and return the verification URL it prints (plus the
    /// user-code, if printed separately). Implementations must keep the
    /// subprocess running so it continues polling Nous until the user
    /// approves and the CLI exits — observed via `awaitCompletion`.
    func requestVerification(
        handle: HermesContainerHandle,
        sessionID: String,
    ) async throws -> (verifyURL: String, userCode: String?)

    /// Await the parked CLI subprocess's exit (it self-completes by polling
    /// once the user approves in their browser). Returns `true` on a clean
    /// (exit code 0) completion.
    func awaitCompletion(
        handle: HermesContainerHandle,
        sessionID: String,
    ) async throws -> Bool

    /// Best-effort cancel for an in-flight session. Idempotent.
    func cancel(sessionID: String) async

    /// Run `hermes auth remove nous` inside the container. Returns `true` on
    /// success. Used when the user disconnects from iOS.
    func revoke(handle: HermesContainerHandle) async throws -> Bool

    /// Best-effort read of the connected subscription's plan/tier string via
    /// `hermes portal status`. Non-throwing — returns `nil` when unavailable
    /// (Nous exposes no programmatic credits balance, only this CLI status).
    func subscriptionPlan(handle: HermesContainerHandle) async -> String?
}

/// Live implementation that drives `hermes auth add nous --type oauth`
/// inside each tenant's Hermes container.
///
/// Flow:
///   1. `requestVerification` spawns a streaming `docker exec` of the CLI,
///      tails stdout until it sees the verification URL (and user-code),
///      parks the still-running process handle in `NousOAuthProcessRegistry`,
///      and returns them. The CLI keeps polling Nous while it waits.
///   2. `awaitCompletion` pulls the parked handle and awaits the CLI's exit
///      code — 0 once the user approved and the token was written.
///   3. `cancel` terminates a parked subprocess (user dismissed the sheet).
///   4. `revoke` runs `hermes auth remove nous` (short-lived command).
///
/// URL/code detection is prefix-based against the documented Hermes wording
/// with several tolerated alternates so a future wording change doesn't
/// immediately break us. NOTE: the exact stdout format must be confirmed
/// against the live `nousresearch/hermes-agent` image — see the prefix lists.
struct LiveNousOAuthBackend: NousOAuthBackend {
    private let docker: any DockerExec
    private let registry: NousOAuthProcessRegistry
    private let logger: Logger
    /// Inside-container path to the hermes CLI. Defaults to the Python venv
    /// install location documented in the Hermes Agent docker guide;
    /// overridable for custom images. Matches `LiveXaiOAuthBackend`.
    private let hermesBinaryPath: String
    /// Max wall-clock seconds to wait for the verification URL line. Hermes
    /// prints it within milliseconds of process start; a long timeout masks
    /// docker spawn failures.
    private let startTimeoutSeconds: Int
    /// Max wall-clock seconds to wait for the CLI to exit after the user
    /// approves. Device-code polling can take as long as the user takes to
    /// approve in their browser, so this is generous.
    private let completeTimeoutSeconds: Int

    /// Lines that introduce the verification URL.
    private static let verifyURLLinePrefixes = [
        "Visit:",
        "Open this URL:",
        "Authorize at:",
        "To authorize, visit",
        "Go to",
    ]
    /// Lines that introduce the device user-code.
    private static let userCodeLinePrefixes = [
        "Enter code:",
        "User code:",
        "user_code:",
        "Code:",
        "and enter code",
    ]

    init(
        docker: any DockerExec,
        registry: NousOAuthProcessRegistry,
        logger: Logger,
        hermesBinaryPath: String = "/opt/hermes/.venv/bin/hermes",
        startTimeoutSeconds: Int = 30,
        completeTimeoutSeconds: Int = 300,
    ) {
        self.docker = docker
        self.registry = registry
        self.logger = logger
        self.hermesBinaryPath = hermesBinaryPath
        self.startTimeoutSeconds = startTimeoutSeconds
        self.completeTimeoutSeconds = completeTimeoutSeconds
    }

    func requestVerification(
        handle: HermesContainerHandle,
        sessionID: String,
    ) async throws -> (verifyURL: String, userCode: String?) {
        let streaming = try await docker.execStreaming(
            container: handle.containerName,
            command: [hermesBinaryPath, "auth", "add", "nous", "--type", "oauth"],
        )

        let parsed = try await withNousTimeout(seconds: startTimeoutSeconds) {
            try await Self.consumeVerification(from: streaming.lines)
        } onTimeout: {
            await streaming.cancel()
            throw NousOAuthError.verifyURLMissingFromStdout
        }

        await registry.put(sessionID: sessionID, handle: streaming)
        logger.info("nous-oauth verification URL emitted", metadata: [
            "sessionID": "\(sessionID)",
            "container": "\(handle.containerName)",
        ])
        return parsed
    }

    func awaitCompletion(
        handle _: HermesContainerHandle,
        sessionID: String,
    ) async throws -> Bool {
        guard let entry = await registry.take(sessionID: sessionID) else {
            throw NousOAuthError.sessionNotFound
        }
        let exitCode = try await withNousTimeout(seconds: completeTimeoutSeconds) {
            try await entry.handle.wait()
        } onTimeout: {
            await entry.handle.cancel()
            throw NousOAuthError.backendFailed(reason: "hermes CLI did not exit within timeout")
        }
        logger.info("nous-oauth CLI exited", metadata: [
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
            command: [hermesBinaryPath, "auth", "remove", "nous"],
        )
        return result.ok
    }

    func subscriptionPlan(handle: HermesContainerHandle) async -> String? {
        let result = try? await docker.exec(
            container: handle.containerName,
            command: [hermesBinaryPath, "portal", "status"],
        )
        guard let result, result.ok else { return nil }
        return Self.extractPlan(from: result.stdout)
    }

    /// Scans `hermes portal status` stdout for a line naming the plan/tier.
    /// Returns the value after the first matching keyword, trimmed. Best
    /// effort — wording confirmed against the live image during build.
    static func extractPlan(from stdout: String) -> String? {
        let keywords = ["plan", "tier", "subscription"]
        for raw in stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            for keyword in keywords where lower.contains(keyword) {
                if let colon = line.firstIndex(of: ":") {
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return value }
                }
                return line.isEmpty ? nil : line
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Reads the streaming line iterator until it has a verification URL.
    /// Collects a user-code if one is printed (separately or embedded in the
    /// URL as `?user_code=…`). Returns as soon as the URL is known.
    static func consumeVerification(
        from lines: AsyncStream<String>,
    ) async throws -> (verifyURL: String, userCode: String?) {
        var foundURL: String?
        var foundCode: String?
        for await line in lines {
            if foundCode == nil, let code = extractUserCode(from: line) {
                foundCode = code
            }
            if foundURL == nil, let url = extractURL(from: line) {
                foundURL = url
            }
            if let url = foundURL {
                // Prefer a standalone code; else fall back to the URL's
                // embedded `user_code` query param.
                return (url, foundCode ?? embeddedUserCode(in: url))
            }
        }
        throw NousOAuthError.verifyURLMissingFromStdout
    }

    /// Returns a verification URL from a line, via a known prefix or by
    /// recognising a bare nousresearch.com https URL.
    static func extractURL(from line: String) -> String? {
        for prefix in verifyURLLinePrefixes where line.contains(prefix) {
            if let url = firstHTTPSToken(in: line) {
                return url
            }
        }
        if let url = firstHTTPSToken(in: line),
           url.contains("nousresearch.com")
        {
            return url
        }
        return nil
    }

    /// Returns a user-code token from a line introduced by a known prefix.
    static func extractUserCode(from line: String) -> String? {
        for prefix in userCodeLinePrefixes where line.contains(prefix) {
            let tail = line.components(separatedBy: prefix).last ?? ""
            let token = tail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .first
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            if let token, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// Extracts the `user_code` query param from a verification URL, if any.
    static func embeddedUserCode(in url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "user_code" })?.value
    }

    /// Returns the first whitespace-delimited token starting with `https://`.
    private static func firstHTTPSToken(in line: String) -> String? {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .first(where: { $0.hasPrefix("https://") })?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
    }
}

enum NousOAuthError: Error, Equatable {
    case notYetImplemented
    case sessionNotFound
    case verifyURLMissingFromStdout
    case backendFailed(reason: String)
}

/// Race the given operation against a timeout. The timeout closure runs once
/// if the deadline is reached and may throw; otherwise the operation's result
/// is returned. (File-scoped twin of the xAI backend's helper.)
private func withNousTimeout<R: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> R,
    onTimeout: @escaping @Sendable () async throws -> Void,
) async throws -> R {
    try await withThrowingTaskGroup(of: NousTimeoutOutcome<R>.self) { group in
        group.addTask {
            try await .completed(operation())
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            return .timedOut
        }
        guard let outcome = try await group.next() else {
            throw NousOAuthError.backendFailed(reason: "timeout race produced no outcome")
        }
        group.cancelAll()
        switch outcome {
        case let .completed(value):
            return value
        case .timedOut:
            try await onTimeout()
            throw NousOAuthError.backendFailed(reason: "operation timed out")
        }
    }
}

private enum NousTimeoutOutcome<R: Sendable> {
    case completed(R)
    case timedOut
}
