@testable import App
import LuminaVaultShared
import Testing

/// The free-lane decision matrix. Pure — no database, no HTTP.
@Suite
struct FreeLanePolicyTests {
    private static func input(
        tier: UserTier,
        mode: LLMBrainMode = .managed,
        hasKey: Bool = false,
        platformAvailable: Bool = true,
        enabled: Bool = true
    ) -> FreeLanePolicy.Input {
        FreeLanePolicy.Input(
            effectiveTier: tier,
            requestedMode: mode,
            hasUsableUserCredential: hasKey,
            platformPaidManagedAvailable: platformAvailable,
            freeLaneEnabled: enabled
        )
    }

    @Test("lapsed managed user is forced onto the free lane")
    func lapsedManagedIsForced() {
        let verdict = FreeLanePolicy.evaluate(Self.input(tier: .lapsed))
        #expect(verdict == FreeLaneVerdict(trigger: .notEntitled, forced: true))
    }

    /// The case that would otherwise be a 403 dead end: BYOK selected, no key
    /// stored, no entitlement. They get a working free answer instead.
    @Test("lapsed byok user with no key gets the free lane, not a dead end")
    func lapsedByokWithoutKeyIsForced() {
        let verdict = FreeLanePolicy.evaluate(Self.input(tier: .lapsed, mode: .byok, hasKey: false))
        #expect(verdict?.trigger == .notEntitled)
        #expect(verdict?.forced == true)
    }

    @Test("paying and trial tiers keep their own routing", arguments: [UserTier.pro, .ultimate, .trial])
    func entitledTiersAreHonoured(tier: UserTier) {
        #expect(FreeLanePolicy.evaluate(Self.input(tier: tier)) == nil)
        #expect(FreeLanePolicy.honoursUserChoice(Self.input(tier: tier)))
    }

    @Test("byok with a real key is honoured on every tier", arguments: UserTier.allCases)
    func byokWithKeyAlwaysHonoured(tier: UserTier) {
        let verdict = FreeLanePolicy.evaluate(Self.input(tier: tier, mode: .byok, hasKey: true))
        #expect(verdict == nil)
    }

    /// `EntitlementMiddleware` already 402s an archived user before routing;
    /// manufacturing a route here would only hide that.
    @Test("archived never gets a manufactured route")
    func archivedIsUntouched() {
        #expect(FreeLanePolicy.evaluate(Self.input(tier: .archived)) == nil)
        #expect(FreeLanePolicy.evaluate(Self.input(tier: .archived, platformAvailable: false)) == nil)
    }

    @Test(
        "platform outage degrades even a paying user",
        arguments: [UserTier.pro, .ultimate, .trial]
    )
    func platformOutageDegradesPayingUsers(tier: UserTier) {
        let verdict = FreeLanePolicy.evaluate(Self.input(tier: tier, platformAvailable: false))
        #expect(verdict == FreeLaneVerdict(trigger: .platformUnavailable, forced: true))
    }

    /// A paying user whose own key works is unaffected by a platform outage —
    /// we are not the ones being billed.
    @Test("platform outage does not touch a byok user with a key")
    func platformOutageSparesByok() {
        let verdict = FreeLanePolicy.evaluate(
            Self.input(tier: .pro, mode: .byok, hasKey: true, platformAvailable: false)
        )
        #expect(verdict == nil)
    }

    @Test("kill switch disables the lane for every input")
    func killSwitchDisablesEverything() {
        for tier in UserTier.allCases {
            for mode in LLMBrainMode.allCases {
                for hasKey in [true, false] {
                    for platform in [true, false] {
                        let verdict = FreeLanePolicy.evaluate(Self.input(
                            tier: tier,
                            mode: mode,
                            hasKey: hasKey,
                            platformAvailable: platform,
                            enabled: false
                        ))
                        #expect(verdict == nil)
                    }
                }
            }
        }
    }
}
