import Foundation

// MARK: - Tier model

/// Subscription tier. Persisted on `users.tier` as a TEXT column with
/// CHECK constraint (M15_AddTierFields). String-backed so the raw value
/// hits the DB unchanged.
enum UserTier: String, Codable, CaseIterable {
    case trial
    case pro
    case ultimate
    case lapsed
    case archived
}

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
    case privacyBYOKey
    case privacyContextRouter
    case mlxOnDevice
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
        for capability: Capability,
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
            case .trial, .lapsed, .archived: .pro
            }
        case .ultimate:
            .ultimate
        }
    }

    /// Per-capability access table. Mirrors the spec gating matrix:
    /// - Always-on (read your data, export your data): allowed in every
    ///   tier *except* `archived` (where vault is in cold storage).
    /// - Capture / health ingest / chat / memory / built-in skills /
    ///   kb-compile: allowed for trial / pro / ultimate.
    /// - Ultimate-only (vault-authored skills, BYO key, context router,
    ///   MLX on-device): self-evident.
    /// - Lapsed: gets nothing beyond vault read + export.
    /// - Archived: gets nothing — even vault read goes through support.
    private static func matchEntitlement(effective: UserTier, for cap: Capability) -> Bool {
        switch cap {
        case .vaultRead, .vaultExport:
            effective != .archived

        case .capture, .healthIngest, .chat,
             .memoryQuery, .memoGenerator,
             .skillBuiltinRun, .kbCompile:
            switch effective {
            case .trial, .pro, .ultimate: true
            case .lapsed, .archived: false
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
            for: capability,
        )
    }
}
