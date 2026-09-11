@testable import App
import Foundation
import Testing

/// Pure-function tests for `TierOverrideAllowlist`, the parser behind
/// `BILLING_TIER_OVERRIDE_EMAILS`. No DB, no I/O.
///
/// The value is a comma list of `email=tier` entries. A bare email grants
/// `ultimate`; an unknown tier or `none` is dropped rather than stamped.
struct TierOverrideAllowlistTests {
    @Test
    func `empty value grants nothing`() {
        let list = TierOverrideAllowlist(parsing: "")
        #expect(list.isEmpty)
        #expect(list.override(forEmail: "anyone@example.com") == nil)
    }

    @Test
    func `email=tier entries are parsed and looked up case-insensitively`() {
        let list = TierOverrideAllowlist(parsing: "Fernando@GMAIL.com=ultimate, tester@example.com=pro")
        #expect(list.override(forEmail: "fernando@gmail.com") == .ultimate)
        #expect(list.override(forEmail: "FERNANDO@gmail.com") == .ultimate)
        #expect(list.override(forEmail: "tester@example.com") == .pro)
        #expect(list.override(forEmail: "stranger@example.com") == nil)
    }

    @Test
    func `bare email grants ultimate`() {
        let list = TierOverrideAllowlist(parsing: "fernando@gmail.com")
        #expect(list.override(forEmail: "fernando@gmail.com") == .ultimate)
    }

    @Test
    func `unknown tier and none are dropped, the rest survive`() {
        let list = TierOverrideAllowlist(parsing: "a@example.com=gold,b@example.com=none,c@example.com=pro,,=pro")
        #expect(list.override(forEmail: "a@example.com") == nil)
        #expect(list.override(forEmail: "b@example.com") == nil)
        #expect(list.override(forEmail: "c@example.com") == .pro)
        #expect(list.count == 1)
    }

    @Test
    func `whitespace around entries and separators is ignored`() {
        let list = TierOverrideAllowlist(parsing: "  a@example.com = ultimate ,\n b@example.com ")
        #expect(list.override(forEmail: "a@example.com") == .ultimate)
        #expect(list.override(forEmail: "b@example.com") == .ultimate)
    }
}
