import Foundation
import Logging

/// Ops allowlist behind `BILLING_TIER_OVERRIDE_EMAILS`.
///
/// A comma-separated list of `email=tier` entries, e.g.
/// `founder@example.com=ultimate,tester@example.com=pro`. A bare email
/// grants `ultimate`. `DefaultAuthService.issueTokens` consults it on every
/// session — register, password login, refresh, OAuth, magic link, phone —
/// and stamps `users.tier_override` when the stored value differs. That
/// column already wins over the RevenueCat-driven tier in
/// `EntitlementChecker` and exempts the row from `LapseArchiverJob`, so
/// nothing downstream changes; this is the same grant the admin
/// `PUT /v1/admin/users/:id/tier-override` makes, keyed by email and
/// applied automatically.
///
/// Entries naming an unknown tier, or `none`, are dropped with a warning —
/// an allowlist grants; it never revokes.
struct TierOverrideAllowlist: Sendable, Equatable {
    static let empty = TierOverrideAllowlist(overrides: [:])

    /// Lowercased email → override.
    private let overrides: [String: TierOverride]

    private init(overrides: [String: TierOverride]) {
        self.overrides = overrides
    }

    init(parsing raw: String, logger: Logger? = nil) {
        var overrides: [String: TierOverride] = [:]
        for entry in raw.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let email = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty else {
                logger?.warning("tier override allowlist: entry without an email skipped", metadata: ["entry": .string(trimmed)])
                continue
            }

            let tierRaw = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : TierOverride.ultimate.rawValue
            guard let override = TierOverride(rawValue: tierRaw), override != .none else {
                logger?.warning(
                    "tier override allowlist: entry skipped, tier must be pro or ultimate",
                    metadata: ["email": .string(email), "tier": .string(tierRaw)]
                )
                continue
            }
            overrides[email] = override
        }
        self.overrides = overrides
    }

    var isEmpty: Bool {
        overrides.isEmpty
    }

    var count: Int {
        overrides.count
    }

    func override(forEmail email: String) -> TierOverride? {
        overrides[email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
