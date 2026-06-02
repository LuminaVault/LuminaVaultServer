import Foundation

/// Nous Subscription Integration — per-session registry holding the live
/// `hermes auth add nous --type oauth` streaming handle. `LiveNousOAuthBackend`
/// parks the handle here in `requestVerification` (while the CLI polls Nous)
/// and retrieves it in `awaitCompletion` to await the CLI's exit. Mirrors
/// `XaiOAuthProcessRegistry`.
///
/// Entries are evicted in three cases:
///   * `awaitCompletion` finishes (success or failure) — explicit `take`.
///   * `cancel(sessionID:)` from the controller (user dismissed sheet).
///   * Background sweep on entries older than `ttl` (default 10 min) so a
///     forgotten session doesn't leak a docker subprocess.
actor NousOAuthProcessRegistry {
    struct Entry {
        let handle: any StreamingExecHandle
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    init(ttl: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    func put(sessionID: String, handle: any StreamingExecHandle) async {
        await sweep()
        entries[sessionID] = Entry(handle: handle, createdAt: now())
    }

    func take(sessionID: String) async -> Entry? {
        entries.removeValue(forKey: sessionID)
    }

    func cancel(sessionID: String) async {
        if let entry = entries.removeValue(forKey: sessionID) {
            await entry.handle.cancel()
        }
    }

    func count() async -> Int {
        await sweep()
        return entries.count
    }

    private func sweep() async {
        let cutoff = now().addingTimeInterval(-ttl)
        let stale = entries.filter { $0.value.createdAt < cutoff }
        for (id, entry) in stale {
            await entry.handle.cancel()
            entries.removeValue(forKey: id)
        }
    }
}
