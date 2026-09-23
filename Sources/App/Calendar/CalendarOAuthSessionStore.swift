import Foundation

/// HER-340 — in-memory store of in-flight Google Calendar OAuth sessions,
/// keyed by the opaque `state` we mint at `start` and Google echoes back to
/// the server callback. Doubles as CSRF protection (an unknown `state` is
/// rejected) and tenant correlation (the callback is unauthenticated — Google
/// redirects the user's browser, carrying no JWT).
///
/// Sessions expire after `ttl`; `take` is one-shot (consumed on callback).
/// Mirrors `XaiOAuthSessionStore`.
actor CalendarOAuthSessionStore {
    struct Session {
        let state: String
        let tenantID: UUID
        let startedAt: Date
    }

    private var sessions: [String: Session] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    init(ttl: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    func put(_ session: Session) {
        prune()
        sessions[session.state] = session
    }

    /// Consume the session for `state` if present and unexpired.
    func take(state: String) -> Session? {
        prune()
        return sessions.removeValue(forKey: state)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-ttl)
        sessions = sessions.filter { $0.value.startedAt >= cutoff }
    }
}
