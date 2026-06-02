import Foundation

/// Nous Subscription Integration — in-memory store mapping an opaque
/// `sessionID` to the per-tenant `NousOAuthService` start-call state. Mirrors
/// `XaiOAuthSessionStore`; the device-code flow only needs the tenant + start
/// time (for TTL) + the verification URL echoed to iOS. Sessions auto-expire
/// after `ttl` and are reaped lazily on access.
actor NousOAuthSessionStore {
    struct Session {
        let sessionID: String
        let tenantID: UUID
        let verifyURL: String
        let startedAt: Date

        init(sessionID: String, tenantID: UUID, verifyURL: String, startedAt: Date) {
            self.sessionID = sessionID
            self.tenantID = tenantID
            self.verifyURL = verifyURL
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
