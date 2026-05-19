import Foundation

/// HER-240a — in-memory store mapping an opaque `sessionID` to the per-tenant
/// `XaiOAuthService` start-call state. The state holds:
///   * the tenant that initiated the flow,
///   * when it started (used for TTL expiry),
///   * the authorize URL (echoed back to iOS),
///   * an async callback the controller invokes once the iOS app POSTs the
///     captured loopback URL — this resumes the still-running `docker exec
///     hermes auth add xai-oauth --no-browser` subprocess inside the
///     container by forwarding the URL to Hermes' loopback listener.
///
/// Sessions auto-expire after `ttl`; expired sessions are reaped lazily on
/// access. The process pipe associated with an expired session is closed by
/// the service when it observes the TTL elapsed.
actor XaiOAuthSessionStore {
    struct Session: Sendable {
        let sessionID: String
        let tenantID: UUID
        let authorizeURL: String
        let startedAt: Date

        init(sessionID: String, tenantID: UUID, authorizeURL: String, startedAt: Date) {
            self.sessionID = sessionID
            self.tenantID = tenantID
            self.authorizeURL = authorizeURL
            self.startedAt = startedAt
        }
    }

    private var sessions: [String: Session] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    init(ttl: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    func put(_ session: Session) {
        sweep()
        sessions[session.sessionID] = session
    }

    func take(sessionID: String) -> Session? {
        sweep()
        return sessions.removeValue(forKey: sessionID)
    }

    func count() -> Int {
        sweep()
        return sessions.count
    }

    private func sweep() {
        let cutoff = now().addingTimeInterval(-ttl)
        sessions = sessions.filter { $0.value.startedAt >= cutoff }
    }
}
