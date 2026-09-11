@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Pure-function tests for `EntitlementChecker`. No DB, no Hummingbird,
/// no I/O. The full `(tier, override, capability)` matrix has 6 × 3 × 15
/// = 270 cells; we test ~35 representative cells covering every
/// equivalence class, plus the override-never-downgrades invariant.
struct EntitlementCheckerTests {
    /// `workflowAutomation` was defined and mounted on no route, so
    /// `/v1/workflows` — which dispatches LLM work per run — was open to any
    /// authenticated account, `lapsed` and `archived` included.
    ///
    /// Trial is granted deliberately: the tier exists to demonstrate the paid
    /// product, and a trial that cannot open the studio cannot sell the thing
    /// it is trialling.
    @Test
    func `workflow automation is denied only after the trial ends unpaid`() {
        for tier in [UserTier.trial, .pro, .ultimate] {
            #expect(
                EntitlementChecker.entitled(tier: tier, override: .none, for: .workflowAutomation),
                "\(tier) should reach the workflow studio"
            )
        }
        for tier in [UserTier.free, .lapsed, .archived] {
            #expect(
                EntitlementChecker.entitled(tier: tier, override: .none, for: .workflowAutomation) == false,
                "\(tier) must not drive platform inference through workflows"
            )
        }
    }

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

    /// Chat is the free product. Every tier but `archived` holds it — a
    /// non-paying tier reaches an LLM only through `FreeLanePolicy`'s
    /// zero-cost lane, capped daily by `FreeLaneGate`, so entitlement here
    /// costs nothing. Routes that spend a platform key with no
    /// bring-your-own path are gated separately, by `platformFunded`.
    @Test
    func `chat allowed on every tier but archived`() {
        for tier in [UserTier.free, .trial, .pro, .ultimate, .lapsed] {
            #expect(EntitlementChecker.entitled(tier: tier, override: .none, for: .chat),
                    "\(tier) should reach chat")
        }
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .chat))
    }

    /// `/v1/conversations` — the surface the iOS app actually streams chat
    /// through, listing included — is gated on `.memoryQuery`, not `.chat`.
    /// Granting one without the other leaves the Chats tab itself 402ing.
    @Test
    func `memory query tracks chat exactly`() {
        for tier in UserTier.allCases {
            #expect(
                EntitlementChecker.entitled(tier: tier, override: .none, for: .memoryQuery)
                    == EntitlementChecker.entitled(tier: tier, override: .none, for: .chat),
                "\(tier): memoryQuery must not diverge from chat"
            )
        }
    }

    @Test
    func `capture allowed on every tier but archived`() {
        for tier in [UserTier.free, .trial, .pro, .ultimate, .lapsed] {
            #expect(EntitlementChecker.entitled(tier: tier, override: .none, for: .capture))
        }
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .capture))
    }

    @Test
    func `skill builtin run allowed for active tiers`() {
        #expect(EntitlementChecker.entitled(tier: .trial, override: .none, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .pro, override: .none, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .free, override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .lapsed, override: .none, for: .skillBuiltinRun))
        #expect(!EntitlementChecker.entitled(tier: .archived, override: .none, for: .skillBuiltinRun))
    }

    @Test
    func `kb compile allowed for active tiers`() {
        for tier in [UserTier.trial, .pro, .ultimate] {
            #expect(EntitlementChecker.entitled(tier: tier, override: .none, for: .kbCompile))
        }
        for tier in [UserTier.free, .lapsed, .archived] {
            #expect(!EntitlementChecker.entitled(tier: tier, override: .none, for: .kbCompile))
        }
    }

    @Test
    func `memory compile allowed for active tiers`() {
        for tier in [UserTier.trial, .pro, .ultimate] {
            #expect(EntitlementChecker.entitled(tier: tier, override: .none, for: .memoryCompile))
        }
        for tier in [UserTier.free, .lapsed, .archived] {
            #expect(!EntitlementChecker.entitled(tier: tier, override: .none, for: .memoryCompile))
        }
    }

    // MARK: - Ultimate-only capabilities

    @Test
    func `vault skill run ultimate only`() {
        #expect(!EntitlementChecker.entitled(tier: .trial, override: .none, for: .skillVaultRun))
        #expect(!EntitlementChecker.entitled(tier: .pro, override: .none, for: .skillVaultRun))
        #expect(EntitlementChecker.entitled(tier: .ultimate, override: .none, for: .skillVaultRun))
        #expect(!EntitlementChecker.entitled(tier: .free, override: .none, for: .skillVaultRun))
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

    /// The free row, stated exhaustively. Everything outside this set either
    /// spends our money (`healthIngest`, the compilers, workflows, and the
    /// platform-funded routes) or is the paid surface itself.
    static let freeCapabilities: Set<Capability> = [
        .vaultRead, .vaultExport, .chat, .memoryQuery, .capture,
    ]

    @Test
    func `free gets chat memory and capture and nothing else`() {
        for cap in Capability.allCases {
            let allowed = EntitlementChecker.entitled(tier: .free, override: .none, for: cap)
            let expected = Self.freeCapabilities.contains(cap)
            #expect(allowed == expected, "free.\(cap) expected \(expected), got \(allowed)")
        }
    }

    /// An ex-subscriber must never get strictly less than someone who never
    /// paid. The two tiers differ only in the archive clock
    /// (`LapseArchiverJob` runs on `lapsed`, never on `free`) and the storage
    /// ceiling — never in what they can do.
    @Test
    func `lapsed matches free exactly`() {
        for cap in Capability.allCases {
            #expect(
                EntitlementChecker.entitled(tier: .lapsed, override: .none, for: cap)
                    == EntitlementChecker.entitled(tier: .free, override: .none, for: cap),
                "lapsed.\(cap) diverged from free"
            )
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
    func `override pro raises free to pro`() {
        #expect(EntitlementChecker.entitled(tier: .free, override: .pro, for: .skillBuiltinRun))
        #expect(EntitlementChecker.entitled(tier: .free, override: .pro, for: .workflowAutomation))
        #expect(!EntitlementChecker.entitled(tier: .free, override: .pro, for: .skillVaultRun))
        #expect(EntitlementChecker.effectiveTier(tier: .free, override: .pro) == .pro)
        #expect(EntitlementChecker.effectiveTier(tier: .free, override: .ultimate) == .ultimate)
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
        // Vault read survives: a schema-drift bug must not take an
        // authenticated user's own notes away from them.
        #expect(u.entitled(for: .vaultRead))
        // Chat is now granted here, because `lapsed` grants it. Deliberate —
        // the free lane is zero-cost and day-capped, so the blast radius of a
        // row we could not parse is 20 free messages.
        #expect(u.entitled(for: .chat))
        // What the fallback still denies is everything that spends money.
        #expect(!u.entitled(for: .skillBuiltinRun))
        #expect(!u.entitled(for: .workflowAutomation))
        #expect(!u.entitled(for: .skillVaultRun))
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
