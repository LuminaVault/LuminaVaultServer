@testable import App
import Foundation
import Testing

/// HER-193 — pure-logic tests for `SkillManifest.DailyRunCap.value(for:)`.
/// Documents the tier-mapping contract that `SkillRunCapGuard` relies on.
struct DailyRunCapTests {
    private static let cap = SkillManifest.DailyRunCap(trial: 3, pro: 3, ultimate: 0)

    @Test
    func `tier strings map to their declared caps`() {
        #expect(Self.cap.value(for: "trial") == 3)
        #expect(Self.cap.value(for: "pro") == 3)
        #expect(Self.cap.value(for: "ultimate") == 0)
    }

    @Test
    func `tier strings are case insensitive`() {
        #expect(Self.cap.value(for: "ULTIMATE") == 0)
        #expect(Self.cap.value(for: "Pro") == 3)
    }

    @Test
    func `unknown tier defaults to trial cap`() {
        #expect(Self.cap.value(for: "enterprise") == 3)
        #expect(Self.cap.value(for: "") == 3)
    }

    @Test
    func `zero ultimate cap encodes the unlimited contract`() {
        // HER-193 acceptance: "Ultimate user with daily_run_cap.ultimate: 0
        // → no cap check". `SkillRunCapGuard` treats `0` as unlimited.
        let unlimited = SkillManifest.DailyRunCap(trial: 1, pro: 1, ultimate: 0)
        #expect(unlimited.value(for: "ultimate") == 0)
    }
}
