import Foundation
import LuminaVaultShared

/// The store SKUs we sell, and the tier each grants.
///
/// This exists because the webhook used to decide with
/// `pid.contains("ultimate")` then `pid.contains("pro")`. Two things were
/// wrong with that. A SKU matching neither fell through silently — no else,
/// no log — so Apple billed the user, `tier_expires_at` advanced, the event
/// was written to `billing_event_logs` (suppressing any replay), and the tier
/// stayed `trial`. And `"pro"` is a substring of `promo`, `professional` and
/// `product`, so a future promotional SKU would have quietly sold Pro.
///
/// An explicit table has neither failure: an id is either sold here or it is
/// not, and "not" is loud.
enum SubscriptionCatalog {
    struct Product: Sendable, Equatable {
        let id: String
        let tier: UserTier
        /// Display price, for docs and receipts — not used for enforcement.
        let priceUSD: String
        let period: Period

        enum Period: String, Sendable { case monthly, yearly }
    }

    /// Pro $14.99/mo, $149.99/yr. Ultimate $29.99/mo, $299.99/yr.
    static let products: [Product] = [
        Product(id: "pro_monthly_14_99", tier: .pro, priceUSD: "14.99", period: .monthly),
        Product(id: "pro_yearly_149_99", tier: .pro, priceUSD: "149.99", period: .yearly),
        Product(id: "ultimate_monthly_29_99", tier: .ultimate, priceUSD: "29.99", period: .monthly),
        Product(id: "ultimate_yearly_299_99", tier: .ultimate, priceUSD: "299.99", period: .yearly),
    ]

    private static let byID: [String: Product] = Dictionary(
        uniqueKeysWithValues: products.map { ($0.id, $0) }
    )

    /// The tier a store product grants, or `nil` if we do not sell it.
    ///
    /// Exact match, deliberately. A SKU we do not recognise is an operational
    /// error — a product added in App Store Connect but not here — and the
    /// caller must treat it as a failure rather than a no-op.
    static func tier(forProductID id: String) -> UserTier? {
        byID[id]?.tier
    }

    static func product(id: String) -> Product? {
        byID[id]
    }
}
