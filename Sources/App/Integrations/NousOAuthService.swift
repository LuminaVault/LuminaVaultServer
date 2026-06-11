import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Nous Subscription Integration — orchestrates the Nous Portal OAuth
/// device-code flow on behalf of a tenant. Mirrors `XaiOAuthService`, with
/// two simplifications for device-code: `complete` only awaits the polling
/// CLI's exit (no callback URL to forward), and connecting does NOT change
/// the user's LuminaVault tier (it only swaps which subscription funds
/// inference). Steps the controller maps to HTTP routes:
///   * `status`   → "is this tenant connected, and on what plan?"
///   * `start`    → spawn the CLI, return its verification URL + user-code
///   * `complete` → await the CLI's exit, stamp `nous_connected_at`
///   * `revoke`   → `hermes auth remove nous`, clear the marker
actor NousOAuthService {
    struct StartResult {
        let sessionID: String
        let verifyURL: String
        let userCode: String?
    }

    struct Status {
        let connected: Bool
        let nousConnectedAt: Date?
        let plan: String?
    }

    private let containerManager: HermesContainerManager
    private let sessionStore: NousOAuthSessionStore
    private let backend: any NousOAuthBackend
    private let fluent: Fluent
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        containerManager: HermesContainerManager,
        sessionStore: NousOAuthSessionStore,
        backend: any NousOAuthBackend,
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
        guard let handle = try await containerManager.handle(tenantID: tenantID) else {
            return Status(connected: false, nousConnectedAt: nil, plan: nil)
        }
        let connected = handle.nousConnectedAt != nil
        // Only probe the plan when connected — avoids a docker exec on the
        // common disconnected path, and `hermes portal status` is meaningless
        // without a credential.
        let plan = connected ? await backend.subscriptionPlan(handle: handle) : nil
        return Status(connected: connected, nousConnectedAt: handle.nousConnectedAt, plan: plan)
    }

    func start(tenantID: UUID) async throws -> StartResult {
        let handle = try await containerManager.ensureRunning(tenantID: tenantID)
        let sessionID = UUID().uuidString
        let parsed = try await backend.requestVerification(handle: handle, sessionID: sessionID)
        await sessionStore.put(NousOAuthSessionStore.Session(
            sessionID: sessionID,
            tenantID: tenantID,
            verifyURL: parsed.verifyURL,
            startedAt: now()
        ))
        logger.info("nous oauth start", metadata: [
            "tenantID": "\(tenantID)",
            "sessionID": "\(sessionID)",
        ])
        return StartResult(sessionID: sessionID, verifyURL: parsed.verifyURL, userCode: parsed.userCode)
    }

    func complete(sessionID: String) async throws -> Status {
        guard let session = await sessionStore.take(sessionID: sessionID) else {
            throw NousOAuthError.sessionNotFound
        }
        let handle = try await containerManager.ensureRunning(tenantID: session.tenantID)
        let ok = try await backend.awaitCompletion(handle: handle, sessionID: sessionID)
        guard ok else {
            throw NousOAuthError.backendFailed(reason: "backend reported non-zero exit")
        }
        try await containerManager.recordNousConnected(tenantID: session.tenantID, at: now())
        logger.info("nous oauth completed", metadata: [
            "tenantID": "\(session.tenantID)",
            "sessionID": "\(sessionID)",
        ])
        return try await status(tenantID: session.tenantID)
    }

    func revoke(tenantID: UUID) async throws -> Status {
        if let handle = try await containerManager.handle(tenantID: tenantID) {
            _ = try? await backend.revoke(handle: handle)
        }
        try await containerManager.recordNousDisconnected(tenantID: tenantID)
        return try await status(tenantID: tenantID)
    }
}
