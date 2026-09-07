@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Pure-function tests for `BYOEntitlementPolicy`. No DB, no Hummingbird.
///
/// The rule under test: a tenant burning their own compute is not billed for
/// it. Every user becomes `lapsed` 14 days after signup
/// (`LapseArchiverJob`), and `lapsed` denies chat, capture, memory search and
/// the knowledge graph — so before this policy a self-hoster was charged for
/// inference the platform never paid for.
struct BYOEntitlementPolicyTests {
    private static let neither = BYOEntitlementPolicy.Input(
        hasOwnHermes: false,
        hasUsableUserCredential: false
    )
    private static let ownHermes = BYOEntitlementPolicy.Input(
        hasOwnHermes: true,
        hasUsableUserCredential: false
    )
    private static let ownKey = BYOEntitlementPolicy.Input(
        hasOwnHermes: false,
        hasUsableUserCredential: true
    )

    /// The capabilities a lapsed user loses, and the reason this exists.
    private static let billedCapabilities: [Capability] = [
        .chat, .capture, .memoryQuery, .memoGenerator, .memoryCompile, .healthIngest,
    ]

    @Test
    func `no BYO signal means no exemption`() {
        for capability in Capability.allCases {
            for tier in UserTier.allCases {
                #expect(
                    BYOEntitlementPolicy.exemption(for: capability, tier: tier, input: Self.neither) == nil,
                    "\(capability)/\(tier) should not be exempt without a BYO signal"
                )
            }
        }
    }

    @Test
    func `own hermes exempts a lapsed user from every billed capability`() {
        for capability in Self.billedCapabilities {
            #expect(
                BYOEntitlementPolicy.exemption(for: capability, tier: .lapsed, input: Self.ownHermes) == .ownHermes,
                "\(capability) should be exempt for a lapsed BYO-Hermes tenant"
            )
        }
    }

    @Test
    func `own key exempts a lapsed user from every billed capability`() {
        for capability in Self.billedCapabilities {
            #expect(
                BYOEntitlementPolicy.exemption(for: capability, tier: .lapsed, input: Self.ownKey) == .ownKey
            )
        }
    }

    /// Hermes is checked first because it is the free signal — the credential
    /// lookup can cost DB reads.
    @Test
    func `hermes wins when both signals are present`() {
        let both = BYOEntitlementPolicy.Input(hasOwnHermes: true, hasUsableUserCredential: true)
        #expect(BYOEntitlementPolicy.exemption(for: .chat, tier: .lapsed, input: both) == .ownHermes)
    }

    /// The paid surface stays paid. These are not "who pays for the tokens"
    /// questions, so bringing your own compute does not unlock them.
    @Test
    func `ultimate-only capabilities are never exempted`() {
        let ultimateOnly: [Capability] = [.skillVaultRun, .privacyBYOKey, .privacyContextRouter, .mlxOnDevice]
        for capability in ultimateOnly {
            #expect(capability.requiresUltimate, "\(capability) should be classified ultimate-only")
            for input in [Self.ownHermes, Self.ownKey] {
                for tier in UserTier.allCases {
                    #expect(
                        BYOEntitlementPolicy.exemption(for: capability, tier: tier, input: input) == nil,
                        "\(capability) must stay gated even for BYO"
                    )
                }
            }
        }
    }

    /// An archived account is closed, not merely unpaid — its data is
    /// scheduled for deletion, so BYO does not reopen it.
    @Test
    func `archived is never exempted`() {
        for capability in Capability.allCases {
            for input in [Self.ownHermes, Self.ownKey] {
                #expect(BYOEntitlementPolicy.exemption(for: capability, tier: .archived, input: input) == nil)
            }
        }
    }

    /// The policy is only consulted after the tier check fails, but it should
    /// still answer sensibly for paying tiers rather than depend on call order.
    @Test
    func `paying tiers are exempt too, which is harmless because they already pass`() {
        for tier in [UserTier.trial, .pro, .ultimate] {
            #expect(BYOEntitlementPolicy.exemption(for: .chat, tier: tier, input: Self.ownHermes) == .ownHermes)
        }
    }
}
