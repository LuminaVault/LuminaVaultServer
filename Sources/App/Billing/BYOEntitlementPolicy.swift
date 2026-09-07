import Foundation
import LuminaVaultShared

/// Why a request was exempted from the paywall.
enum BYOExemption: String, Sendable, Equatable, Codable {
    /// The tenant routes to their own Hermes gateway.
    case ownHermes
    /// The tenant has at least one provider credential the router could spend.
    case ownKey
}

/// The single statement of who we may charge.
///
/// **A tenant burning their own compute is not billed for it.** Bringing a
/// Hermes instance or a provider key means the platform pays for no inference
/// on their behalf, so gating those capabilities behind a subscription charges
/// for nothing. Everything else stays gated.
///
/// This is the same principle `FreeLanePolicy` already states — *"we are not
/// the ones being billed, so there is nothing to protect"* — lifted to the HTTP
/// layer. `FreeLanePolicy` lives inside the router, strictly downstream of
/// `EntitlementMiddleware`, so a `lapsed` BYO tenant was rejected with a 402
/// before it ever ran.
///
/// Pure: no Fluent, no Hummingbird, no I/O, so the matrix is exhaustively
/// testable and there is exactly one place to read when the question is "why
/// was this user asked to pay".
enum BYOEntitlementPolicy {
    struct Input: Sendable {
        /// `HermesEndpointResolver.Resolution.isUserOverride` — the tenant
        /// resolves to their own gateway rather than the managed default.
        let hasOwnHermes: Bool
        /// Any credential row the router could actually spend
        /// (`CerberusRouterService.credentialedProviderIDs` non-empty).
        let hasUsableUserCredential: Bool

        init(hasOwnHermes: Bool, hasUsableUserCredential: Bool) {
            self.hasOwnHermes = hasOwnHermes
            self.hasUsableUserCredential = hasUsableUserCredential
        }
    }

    /// `nil` ⇒ no exemption; the caller applies the normal entitlement check.
    ///
    /// The four `requiresUltimate` capabilities are deliberately **not**
    /// exempted. They are not "who pays for the tokens" questions — they are
    /// the product's paid surface, and a self-hoster gets them by subscribing
    /// like anyone else.
    ///
    /// `archived` is likewise never exempted: an archived account is closed,
    /// not merely unpaid, and its data is scheduled for deletion.
    static func exemption(
        for capability: Capability,
        tier: UserTier,
        input: Input
    ) -> BYOExemption? {
        guard tier != .archived else { return nil }
        guard !capability.requiresUltimate else { return nil }
        if input.hasOwnHermes {
            return .ownHermes
        }
        if input.hasUsableUserCredential {
            return .ownKey
        }
        return nil
    }
}
