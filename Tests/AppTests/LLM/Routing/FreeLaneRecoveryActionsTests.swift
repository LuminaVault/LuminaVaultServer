@testable import App
import LuminaVaultShared
import Testing

/// Which ways out an unavailable free lane offers, by who is asking.
struct FreeLaneRecoveryActionsTests {
    @Test(arguments: [UserTier.free, .lapsed])
    func `unpaid tiers are offered an upgrade or a key`(tier: UserTier) {
        #expect(FreeLanePolicy.recoveryActions(effectiveTier: tier, requestedMode: .managed, trigger: .notEntitled)
            == ["upgrade", "add_key"])
    }

    /// Rule 2b: an entitled account on BYOK with no key. Managed is right there.
    @Test(arguments: [UserTier.trial, .pro, .ultimate])
    func `entitled byok without a key is offered managed, never an upgrade`(tier: UserTier) {
        #expect(FreeLanePolicy.recoveryActions(effectiveTier: tier, requestedMode: .byok, trigger: .notEntitled)
            == ["add_key", "switch_to_managed"])
    }

    /// The lane was entered because managed is down, so offering it is a lie.
    @Test(arguments: [UserTier.trial, .pro, .ultimate])
    func `a platform outage offers only a key`(tier: UserTier) {
        #expect(FreeLanePolicy.recoveryActions(effectiveTier: tier, requestedMode: .managed, trigger: .platformUnavailable)
            == ["add_key"])
        #expect(FreeLanePolicy.recoveryActions(effectiveTier: tier, requestedMode: .byok, trigger: .platformUnavailable)
            == ["add_key"])
    }
}
