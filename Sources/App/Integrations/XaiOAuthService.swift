import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-240a — orchestrates the xAI Grok OAuth flow on behalf of a tenant.
/// Splits the flow into four steps the controller maps to HTTP routes:
///   * `status`     → "is this tenant connected today?"
///   * `start`      → spawn the CLI, return its authorize URL + a sessionID
///   * `complete`   → forward the captured callback URL, await success,
///                    flip `user.tier` to `premium`, stamp `xai_connected_at`
///   * `revoke`     → reverse of complete
actor XaiOAuthService {
    struct StartResult {
        let sessionID: String
        let authorizeURL: String
        init(sessionID: String, authorizeURL: String) {
            self.sessionID = sessionID
            self.authorizeURL = authorizeURL
        }
    }

    struct Status {
        let connected: Bool
        let tier: String
        let xaiConnectedAt: Date?
        init(connected: Bool, tier: String, xaiConnectedAt: Date?) {
            self.connected = connected
            self.tier = tier
            self.xaiConnectedAt = xaiConnectedAt
        }
    }

    private let containerManager: HermesContainerManager
    private let sessionStore: XaiOAuthSessionStore
    private let backend: any XaiOAuthBackend
    private let fluent: Fluent
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        containerManager: HermesContainerManager,
        sessionStore: XaiOAuthSessionStore,
        backend: any XaiOAuthBackend,
        fluent: Fluent,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerManager = containerManager
        self.sessionStore = sessionStore
        self.backend = backend
        self.fluent = fluent
        self.logger = logger
        self.now = now
    }

    func status(tenantID: UUID) async throws -> Status {
        let handle = try await containerManager.handle(tenantID: tenantID)
        let user = try await User.find(tenantID, on: fluent.db())
        return Status(
            connected: handle?.xaiConnectedAt != nil,
            tier: user?.tier ?? "free",
            xaiConnectedAt: handle?.xaiConnectedAt
        )
    }

    func start(tenantID: UUID) async throws -> StartResult {
        let handle = try await containerManager.ensureRunning(tenantID: tenantID)
        let sessionID = UUID().uuidString
        let authorizeURL = try await backend.requestAuthorizeURL(handle: handle, sessionID: sessionID)
        await sessionStore.put(XaiOAuthSessionStore.Session(
            sessionID: sessionID,
            tenantID: tenantID,
            authorizeURL: authorizeURL,
            startedAt: now()
        ))
        logger.info("xai oauth start", metadata: [
            "tenantID": "\(tenantID)",
            "sessionID": "\(sessionID)",
        ])
        return StartResult(sessionID: sessionID, authorizeURL: authorizeURL)
    }

    func complete(sessionID: String, callbackURL: String) async throws -> Status {
        guard let session = await sessionStore.take(sessionID: sessionID) else {
            throw XaiOAuthError.sessionNotFound
        }
        let handle = try await containerManager.ensureRunning(tenantID: session.tenantID)
        let ok = try await backend.submitCallback(
            handle: handle,
            sessionID: sessionID,
            callbackURL: callbackURL
        )
        guard ok else {
            throw XaiOAuthError.backendFailed(reason: "backend reported non-zero exit")
        }
        let connectedAt = now()
        try await containerManager.recordXaiConnected(tenantID: session.tenantID, at: connectedAt)
        // Promote to the `pro` tier. The xAI auth server only completes
        // OAuth for SuperGrok subscribers, so a successful flow is
        // sufficient proof of an entry-level paid subscription. The
        // `users_tier_check` constraint allows trial|pro|ultimate|lapsed|
        // archived; xai unlocks `pro` (one rung up from `trial`).
        if let user = try await User.find(session.tenantID, on: fluent.db()) {
            user.tier = "pro"
            try await user.update(on: fluent.db())
        }
        logger.info("xai oauth completed; user promoted to pro", metadata: [
            "tenantID": "\(session.tenantID)",
            "sessionID": "\(sessionID)",
        ])
        return try await status(tenantID: session.tenantID)
    }

    func revoke(tenantID: UUID) async throws -> Status {
        if let handle = try await containerManager.handle(tenantID: tenantID) {
            _ = try? await backend.revoke(handle: handle)
        }
        try await containerManager.recordXaiDisconnected(tenantID: tenantID)
        if let user = try await User.find(tenantID, on: fluent.db()) {
            // Demote back to trial. The constraint set is
            // trial|pro|ultimate|lapsed|archived — "trial" is the lowest
            // free-equivalent tier.
            user.tier = "trial"
            try await user.update(on: fluent.db())
        }
        return try await status(tenantID: tenantID)
    }
}
