@testable import App
import Foundation
import Testing

/// Retention policy for `usage_events`.
///
/// The table was low-volume — a row per memory-compile run — until voice
/// metering started writing one per transcription attempt. Nothing breaks
/// soon, which is exactly why it needs a policy now: unbounded growth becomes
/// a slow problem nobody attributes to the change that caused it.
///
/// The arithmetic is pinned here; the DELETE itself needs a database and is
/// covered by the integration suite.
struct UsageEventsRetentionTests {
    // MARK: - Enablement

    /// Off by default. Deleting a tenant's usage history is irreversible, so
    /// it must be something an operator turns on deliberately, not something
    /// that starts happening because a service was wired in.
    @Test
    func `zero days disables retention`() {
        #expect(UsageEventsRetentionPolicy(retentionDays: 0).isEnabled == false)
        #expect(UsageEventsRetentionPolicy(retentionDays: -30).isEnabled == false)
    }

    @Test
    func `a positive window enables retention`() {
        #expect(UsageEventsRetentionPolicy(retentionDays: 90).isEnabled)
    }

    // MARK: - Cutoff

    @Test
    func `the cutoff is the window measured back from now`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-12T00:00:00Z"))
        let policy = UsageEventsRetentionPolicy(retentionDays: 90)
        let cutoff = try #require(policy.cutoff(now: now))
        // 90 days before 2026-09-12 is 2026-06-14.
        #expect(ISO8601DateFormatter().string(from: cutoff) == "2026-06-14T00:00:00Z")
    }

    /// A disabled policy has no cutoff at all, rather than one so far back it
    /// happens to delete nothing. A caller that forgets to check `isEnabled`
    /// then gets `nil` and cannot issue the DELETE by accident.
    @Test
    func `a disabled policy has no cutoff`() {
        #expect(UsageEventsRetentionPolicy(retentionDays: 0).cutoff(now: Date()) == nil)
    }

    // MARK: - Batching

    /// Deleted in batches so one sweep cannot hold a long transaction over a
    /// table the hot path is inserting into.
    @Test
    func `the batch size is bounded and positive`() {
        let policy = UsageEventsRetentionPolicy(retentionDays: 90)
        #expect(policy.batchSize > 0)
        #expect(policy.batchSize <= 10000)
    }

    @Test
    func `an absurd configured batch size is clamped`() {
        #expect(UsageEventsRetentionPolicy(retentionDays: 90, batchSize: 10_000_000).batchSize == 10000)
        #expect(UsageEventsRetentionPolicy(retentionDays: 90, batchSize: 0).batchSize == 1)
    }
}
