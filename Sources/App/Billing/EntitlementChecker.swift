import Foundation
import LuminaVaultShared

// MARK: - Tier model

// `UserTier` is sourced from `LuminaVaultShared` (HER-185). The
// historical server-local duplicate was removed in HER-183 cleanup
// because it shadowed the shared one and broke test-target builds
// once both modules were in scope.

/// Ops-set override that lets us grant entitlement bypassing RevenueCat
/// (TestFlight users, internal team, support cases). Always wins over
/// the RC-driven `tier`. `.none` means "respect tier as-is".
enum TierOverride: String, Codable, CaseIterable {
    case none
    case pro
    case ultimate
}

// MARK: - Capability surface

/// Every gate-able server capability. New protected endpoint = new case
/// here + a row in `EntitlementChecker.matchEntitlement`. Strings are stable
/// — kept in sync with the gating matrix in `docs/superpowers/specs/2026-05-10-billing-tiers-revenuecat-design.md`.
enum Capability: String, CaseIterable {
    case vaultRead
    case vaultExport
    case capture
    case healthIngest
    case chat
    case memoryQuery
    case memoGenerator
    case skillBuiltinRun
    case skillVaultRun
    case kbCompile
    case memoryCompile
    case privacyBYOKey
    case privacyContextRouter
    case mlxOnDevice
    case workflowAutomation
}

// MARK: - Checker

/// Pure decision function: given (tier, override, capability) → allowed?
///
/// No DB, no Hummingbird, no logging side effects. Unit-testable in
/// isolation. `EntitlementMiddleware` (HER-187) is the only consumer in
/// production; tests in `EntitlementCheckerTests` exhaustively cover the
/// matrix.
enum EntitlementChecker {
    /// True if a user with the given `tier` (post-`override` application)
    /// is entitled to invoke `capability`.
    static func entitled(
        tier: UserTier,
        override: TierOverride,
        for capability: Capability
    ) -> Bool {
        let effective = effectiveTier(tier: tier, override: override)
        return matchEntitlement(effective: effective, for: capability)
    }

    /// Override semantics: `.pro` / `.ultimate` raise the floor; `.none`
    /// is a pass-through. Override never *lowers* the tier — a user whose
    /// RC-driven `tier == ultimate` with `override == pro` stays Ultimate
    /// (so support can't accidentally downgrade).
    static func effectiveTier(tier: UserTier, override: TierOverride) -> UserTier {
        switch override {
        case .none:
            tier
        case .pro:
            // Override to Pro only if current tier is below Pro.
            switch tier {
            case .ultimate: .ultimate // never downgrade
            case .pro: .pro
            case .free, .trial, .lapsed, .archived: .pro
            }
        case .ultimate:
            .ultimate
        }
    }

    /// Per-capability access table. Mirrors the spec gating matrix:
    /// - Always-on (read your data, export your data): allowed in every
    ///   tier *except* `archived` (where vault is in cold storage).
    /// - Chat / memory query / capture: allowed on **every** tier but
    ///   `archived`. These are the free product. Non-paying tiers reach an
    ///   LLM only through `FreeLanePolicy`'s zero-cost lane, capped per day
    ///   by `FreeLaneGate`, so "entitled" here costs us nothing by
    ///   construction. Routes that spend a platform key with no
    ///   bring-your-own path are *not* covered by this — they are gated
    ///   separately by `EntitlementMiddleware.platformFunded`.
    /// - Health ingest / memo generator / built-in skills / kb-compile /
    ///   memory-compile / workflow automation: trial / pro / ultimate.
    /// - Ultimate-only (vault-authored skills, BYO key, context router,
    ///   MLX on-device): self-evident.
    /// - Free and lapsed share a row. An ex-subscriber getting strictly less
    ///   than someone who never paid is indefensible; they differ only in
    ///   the archive clock (`LapseArchiverJob` runs on `lapsed`, never on
    ///   `free`) and the storage ceiling.
    /// - Archived: gets nothing — even vault read goes through support.
    private static func matchEntitlement(effective: UserTier, for cap: Capability) -> Bool {
        switch cap {
        case .vaultRead, .vaultExport:
            effective != .archived

        case .chat, .memoryQuery, .capture:
            effective != .archived

        case .healthIngest, .memoGenerator,
             .skillBuiltinRun, .kbCompile, .memoryCompile:
            switch effective {
            case .trial, .pro, .ultimate: true
            case .free, .lapsed, .archived: false
            }

        // Trial is included deliberately. The tier exists to demonstrate the
        // paid product, and Automation is the flagship of the Pro tier — a
        // trial that cannot open the studio cannot sell the thing it is
        // trialling. The gate that matters here is `lapsed`, which until this
        // capability was mounted could run LLM-calling workflows for free
        // forever.
        case .workflowAutomation:
            switch effective {
            case .trial, .pro, .ultimate: true
            case .free, .lapsed, .archived: false
            }

        case .skillVaultRun, .privacyBYOKey, .privacyContextRouter, .mlxOnDevice:
            effective == .ultimate
        }
    }
}

// MARK: - Convenience accessors on User

extension User {
    /// Decoded tier. Falls back to `.lapsed` if the DB row holds an
    /// unrecognized value — fail-safe rather than crash on schema drift.
    ///
    /// Still `.lapsed` and not `.free`, though the two now share a capability
    /// row: `lapsed` is the lower of the two everywhere it still differs (no
    /// storage growth), so it remains the conservative choice.
    ///
    /// Note what this fallback no longer buys: `lapsed` grants chat now, so an
    /// unparseable row does reach the free lane. That is deliberate rather
    /// than overlooked — the lane is zero-cost and day-capped, whereas falling
    /// back to `.archived` to deny it would take vault read away from a real,
    /// authenticated user over a schema-drift bug. Losing your notes is the
    /// worse failure than being handed 20 free messages.
    var tierEnum: UserTier {
        UserTier(rawValue: tier) ?? .lapsed
    }

    /// Decoded override. Falls back to `.none` on unrecognized value.
    var tierOverrideEnum: TierOverride {
        TierOverride(rawValue: tierOverride) ?? .none
    }

    /// True if the user is currently entitled to `capability`. Reads the
    /// `tier` + `tier_override` columns; no DB round-trip.
    func entitled(for capability: Capability) -> Bool {
        EntitlementChecker.entitled(
            tier: tierEnum,
            override: tierOverrideEnum,
            for: capability
        )
    }
}
