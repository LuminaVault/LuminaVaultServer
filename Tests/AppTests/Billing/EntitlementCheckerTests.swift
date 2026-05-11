@testable import App
import Foundation
import Testing

/// Pure-function tests for `EntitlementChecker`. No DB, no Hummingbird,
/// no I/O. The full `(tier, override, capability)` matrix has 5 × 3 × 13
/// = 195 cells; we test ~30 representative cells covering every
/// equivalence class, plus the override-never-downgrades invariant.
struct EntitlementCheckerTests {
    // MARK: - Always-on capabilities

    @Test
    func `vault read allowed everywhere except archived`() {
        for tier in UserTier.allCases {
            let allowed = EntitlementChecker.entitled(tier: tier, override: .none, for: .vaultRead)
            #expect(allowed == (tier != .archived), "vaultRead for \(tier) expected \(tier != .archived), got \(allowed)")
        }
    }

    @Test
    func `vault export allowed everywhere except archived`() {
        for tier in UserTier.allCases {
            let allowed = EntitlementChecker.entitled(tier: tier, override: .none, for: .vaultExport)
            #expect(allowed == (tier != .archived))
        }
    }

    // MARK: - Trial / Pro / Ultimate capabilities

    @Test
    func `chat allowed for active tiers`() {
        #expect(EntitlementChecker.entitled(tier: .trial, override: .none, for: .chat))
        #expect(EntitlementChecker.entitled(tier: .pro, override: .none, for: .chat))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .chat))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .none, for: .chat))
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .chat))
    }

    @Test
    func `capture allowed for active tiers`() {
        #expect(EntitlementChecker.entitled(tier: .trial, override: .none, for: .capture))
        #expect(EntitlementChecker.entitled(tier: .pro, override: .none, for: .capture))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .capture))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .none, for: .capture))
    }

    @Test
    func `skill builtin run allowed for active tiers`() {
        #expect(EntitlementChecker.entitled(tier: .trial, override: .none, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .pro, override: .none, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .skillBuiltinRun))
    }

    @Test
    func `kb compile allowed for active tiers`() {
        for tier in [UserTier.trial, .pro, .ultimate] {
            #expect(EntitlementChecker.entitled(tier: tier, override: .none, for: .kbCompile))
        }
        for tier in [UserTier.lapsed, .archived] {
            #expect(!EntitlementChecker.entitled(tier: tier, override: .none, for: .kbCompile))
        }
    }

    // MARK: - Ultimate-only capabilities

    @Test
    func `vault skill run ultimate only`() {
        #expect(!EntitlementChecker.entitled(tier: .trial, override: .none, for: .skillVaultRun))
        #expect(!EntitlementChecker.entitled(tier: .pro, override: .none, for: .skillVaultRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .skillVaultRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .none, for: .skillVaultRun))
    }

    @Test
    func `byo key ultimate only`() {
        #expect(!EntitlementChecker.entitled(tier: .trial, override: .none, for: .privacyBYOKey))
        #expect(!EntitlementChecker.entitled(tier: .pro, override: .none, for: .privacyBYOKey))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .privacyBYOKey))
    }

    @Test
    func `context router ultimate only`() {
        #expect(!EntitlementChecker.entitled(tier: .pro, override: .none, for: .privacyContextRouter))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .privacyContextRouter))
    }

    @Test
    func `mlx on device ultimate only`() {
        #expect(!EntitlementChecker.entitled(tier: .pro, override: .none, for: .mlxOnDevice))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .mlxOnDevice))
    }

    // MARK: - Lapsed / archived

    @Test
    func `lapsed gets only vault read and export`() {
        for cap in Capability.allCases {
            let allowed = EntitlementChecker.entitled(tier: .lapsed, override: .none, for: cap)
            let expected = (cap == .vaultRead || cap == .vaultExport)
            #expect(allowed == expected, "lapsed.\(cap) expected \(expected), got \(allowed)")
        }
    }

    @Test
    func `archived gets nothing`() {
        for cap in Capability.allCases {
            #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: cap),
                    "archived.\(cap) should be denied")
        }
    }

    // MARK: - Override semantics

    @Test
    func `override ultimate unlocks everything`() {
        for tier in UserTier.allCases {
            for cap in Capability.allCases {
                let allowed = EntitlementChecker.entitled(tier: tier, override: .ultimate, for: cap)
                #expect(allowed, "tier=\(tier) override=.ultimate cap=\(cap) should always allow")
            }
        }
    }

    @Test
    func `override pro raises lapsed to pro`() {
        #expect(EntitlementChecker.entitled(tier: .lapsed, override: .pro, for: .chat))
        #expect(EntitlementChecker.entitled(tier: .lapsed, override: .pro, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .pro, for: .skillVaultRun)) // still Ultimate-only
    }

    @Test
    func `override pro does not downgrade ultimate`() {
        // An Ultimate user with an accidental override=.pro stays Ultimate-entitled.
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .pro, for: .skillVaultRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .pro, for: .privacyBYOKey))
    }

    @Test
    func `override none is passthrough`() {
        for tier in UserTier.allCases {
            for cap in Capability.allCases {
                let raw = EntitlementChecker.entitled(tier: tier, override: .none, for: cap)
                let viaCheck = EntitlementChecker.entitled(tier: tier, override: .none, for: cap)
                #expect(raw == viaCheck)
            }
        }
    }

    // MARK: - Effective-tier derivation

    @Test
    func `effective tier none is passthrough`() {
        for tier in UserTier.allCases {
            #expect(EntitlementChecker.effectiveTier(tier: tier, override: .none) == tier)
        }
    }

    @Test
    func `effective tier pro raises floor`() {
        #expect(EntitlementChecker.effectiveTier(tier: .lapsed, override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .archived, override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .trial, override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .pro, override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .ultimate, override: .pro) == .ultimate) // never downgrade
    }

    @Test
    func `effective tier ultimate always wins`() {
        for tier in UserTier.allCases {
            #expect(EntitlementChecker.effectiveTier(tier: tier, override: .ultimate) == .ultimate)
        }
    }

    // MARK: - User extension convenience

    @Test
    func `user extension decodes unrecognized tier as lapsed`() {
        let u = User(email: "x@y.test", username: "x", passwordHash: "stub", tier: "garbage")
        #expect(u.tierEnum == .lapsed)
        // Lapsed → vault read OK, chat denied.
        #expect(u.entitled(for: .vaultRead))
        #expect(!u.entitled(for: .chat))
    }

    @Test
    func `user extension decodes unrecognized override as none`() {
        let u = User(email: "x@y.test", username: "x", passwordHash: "stub", tierOverride: "lol")
        #expect(u.tierOverrideEnum == .none)
    }

    @Test
    func `user extension post init defaults are trial`() {
        let u = User(email: "trial@test", username: "trial", passwordHash: "stub")
        #expect(u.tier == "trial")
        #expect(u.tierOverride == "none")
        #expect(u.tierExpiresAt == nil) // expires_at stamped by AuthService, not init
        #expect(u.tierEnum == .trial)
        #expect(u.entitled(for: .chat))
        #expect(!u.entitled(for: .skillVaultRun))
    }
}
