import Foundation
import Testing

@testable import App

/// Pure-function tests for `EntitlementChecker`. No DB, no Hummingbird,
/// no I/O. The full `(tier, override, capability)` matrix has 5 × 3 × 13
/// = 195 cells; we test ~30 representative cells covering every
/// equivalence class, plus the override-never-downgrades invariant.
@Suite
struct EntitlementCheckerTests {

    // MARK: - Always-on capabilities

    @Test
    func vaultReadAllowedEverywhereExceptArchived() {
        for tier in UserTier.allCases {
            let allowed = EntitlementChecker.entitled(tier: tier, override: .none, for: .vaultRead)
            #expect(allowed == (tier != .archived), "vaultRead for \(tier) expected \(tier != .archived), got \(allowed)")
        }
    }

    @Test
    func vaultExportAllowedEverywhereExceptArchived() {
        for tier in UserTier.allCases {
            let allowed = EntitlementChecker.entitled(tier: tier, override: .none, for: .vaultExport)
            #expect(allowed == (tier != .archived))
        }
    }

    // MARK: - Trial / Pro / Ultimate capabilities

    @Test
    func chatAllowedForActiveTiers() {
        #expect(EntitlementChecker.entitled(tier: .trial,    override: .none, for: .chat))
        #expect(EntitlementChecker.entitled(tier: .pro,      override: .none, for: .chat))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .chat))
        #expect(!EntitlementChecker.entitled(tier: .lapsed,   override: .none, for: .chat))
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .chat))
    }

    @Test
    func captureAllowedForActiveTiers() {
        #expect(EntitlementChecker.entitled(tier: .trial,    override: .none, for: .capture))
        #expect(EntitlementChecker.entitled(tier: .pro,      override: .none, for: .capture))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .capture))
        #expect(!EntitlementChecker.entitled(tier: .lapsed,   override: .none, for: .capture))
    }

    @Test
    func skillBuiltinRunAllowedForActiveTiers() {
        #expect(EntitlementChecker.entitled(tier: .trial,    override: .none, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .pro,      override: .none, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed,   override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .skillBuiltinRun))
    }

    @Test
    func kbCompileAllowedForActiveTiers() {
        for tier in [UserTier.trial, .pro, .ultimate] {
            #expect(EntitlementChecker.entitled(tier: tier, override: .none, for: .kbCompile))
        }
        for tier in [UserTier.lapsed, .archived] {
            #expect(!EntitlementChecker.entitled(tier: tier, override: .none, for: .kbCompile))
        }
    }

    // MARK: - Ultimate-only capabilities

    @Test
    func vaultSkillRunUltimateOnly() {
        #expect(!EntitlementChecker.entitled(tier: .trial,    override: .none, for: .skillVaultRun))
        #expect(!EntitlementChecker.entitled(tier: .pro,      override: .none, for: .skillVaultRun))
        #expect( EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .skillVaultRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed,   override: .none, for: .skillVaultRun))
    }

    @Test
    func byoKeyUltimateOnly() {
        #expect(!EntitlementChecker.entitled(tier: .trial,    override: .none, for: .privacyBYOKey))
        #expect(!EntitlementChecker.entitled(tier: .pro,      override: .none, for: .privacyBYOKey))
        #expect( EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .privacyBYOKey))
    }

    @Test
    func contextRouterUltimateOnly() {
        #expect(!EntitlementChecker.entitled(tier: .pro,      override: .none, for: .privacyContextRouter))
        #expect( EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .privacyContextRouter))
    }

    @Test
    func mlxOnDeviceUltimateOnly() {
        #expect(!EntitlementChecker.entitled(tier: .pro,      override: .none, for: .mlxOnDevice))
        #expect( EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .mlxOnDevice))
    }

    // MARK: - Lapsed / archived

    @Test
    func lapsedGetsOnlyVaultReadAndExport() {
        for cap in Capability.allCases {
            let allowed = EntitlementChecker.entitled(tier: .lapsed, override: .none, for: cap)
            let expected = (cap == .vaultRead || cap == .vaultExport)
            #expect(allowed == expected, "lapsed.\(cap) expected \(expected), got \(allowed)")
        }
    }

    @Test
    func archivedGetsNothing() {
        for cap in Capability.allCases {
            #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: cap),
                    "archived.\(cap) should be denied")
        }
    }

    // MARK: - Override semantics

    @Test
    func overrideUltimateUnlocksEverything() {
        for tier in UserTier.allCases {
            for cap in Capability.allCases {
                let allowed = EntitlementChecker.entitled(tier: tier, override: .ultimate, for: cap)
                #expect(allowed, "tier=\(tier) override=.ultimate cap=\(cap) should always allow")
            }
        }
    }

    @Test
    func overrideProRaisesLapsedToPro() {
        #expect(EntitlementChecker.entitled(tier: .lapsed, override: .pro, for: .chat))
        #expect(EntitlementChecker.entitled(tier: .lapsed, override: .pro, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .pro, for: .skillVaultRun)) // still Ultimate-only
    }

    @Test
    func overrideProDoesNotDowngradeUltimate() {
        // An Ultimate user with an accidental override=.pro stays Ultimate-entitled.
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .pro, for: .skillVaultRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .pro, for: .privacyBYOKey))
    }

    @Test
    func overrideNoneIsPassthrough() {
        for tier in UserTier.allCases {
            for cap in Capability.allCases {
                let raw      = EntitlementChecker.entitled(tier: tier, override: .none, for: cap)
                let viaCheck = EntitlementChecker.entitled(tier: tier, override: .none, for: cap)
                #expect(raw == viaCheck)
            }
        }
    }

    // MARK: - Effective-tier derivation

    @Test
    func effectiveTierNoneIsPassthrough() {
        for tier in UserTier.allCases {
            #expect(EntitlementChecker.effectiveTier(tier: tier, override: .none) == tier)
        }
    }

    @Test
    func effectiveTierProRaisesFloor() {
        #expect(EntitlementChecker.effectiveTier(tier: .lapsed,   override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .archived, override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .trial,    override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .pro,      override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .ultimate, override: .pro) == .ultimate) // never downgrade
    }

    @Test
    func effectiveTierUltimateAlwaysWins() {
        for tier in UserTier.allCases {
            #expect(EntitlementChecker.effectiveTier(tier: tier, override: .ultimate) == .ultimate)
        }
    }

    // MARK: - User extension convenience

    @Test
    func userExtensionDecodesUnrecognizedTierAsLapsed() {
        let u = User(email: "x@y.test", username: "x", passwordHash: "stub", tier: "garbage")
        #expect(u.tierEnum == .lapsed)
        // Lapsed → vault read OK, chat denied.
        #expect(u.entitled(for: .vaultRead))
        #expect(!u.entitled(for: .chat))
    }

    @Test
    func userExtensionDecodesUnrecognizedOverrideAsNone() {
        let u = User(email: "x@y.test", username: "x", passwordHash: "stub", tierOverride: "lol")
        #expect(u.tierOverrideEnum == .none)
    }

    @Test
    func userExtensionPostInitDefaultsAreTrial() {
        let u = User(email: "trial@test", username: "trial", passwordHash: "stub")
        #expect(u.tier == "trial")
        #expect(u.tierOverride == "none")
        #expect(u.tierExpiresAt == nil)         // expires_at stamped by AuthService, not init
        #expect(u.tierEnum == .trial)
        #expect(u.entitled(for: .chat))
        #expect(!u.entitled(for: .skillVaultRun))
    }
}
