@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// The SKU table that replaced substring matching.
///
/// The webhook used to decide with `pid.contains("ultimate")` then
/// `pid.contains("pro")`. A SKU matching neither fell through silently, so
/// Apple billed the user and the tier stayed `trial`; and `"pro"` matches
/// inside ordinary words, so a promotional SKU would have sold Pro.
struct SubscriptionCatalogTests {
    @Test
    func `the four sold products map to their tiers`() {
        #expect(SubscriptionCatalog.tier(forProductID: "pro_monthly_14_99") == .pro)
        #expect(SubscriptionCatalog.tier(forProductID: "pro_yearly_149_99") == .pro)
        #expect(SubscriptionCatalog.tier(forProductID: "ultimate_monthly_29_99") == .ultimate)
        #expect(SubscriptionCatalog.tier(forProductID: "ultimate_yearly_299_99") == .ultimate)
    }

    /// The substring bug, pinned. Every one of these used to sell a tier.
    @Test
    func `words containing pro or ultimate do not sell anything`() {
        for id in [
            "promo_launch_2026",
            "professional_services_addon",
            "product_bundle",
            "lifetime_ultimate_upgrade_voucher",
            "pro",
            "ultimate",
        ] {
            #expect(
                SubscriptionCatalog.tier(forProductID: id) == nil,
                "\(id) must not grant a tier — it is not a product we sell"
            )
        }
    }

    @Test
    func `an unknown product grants nothing`() {
        #expect(SubscriptionCatalog.tier(forProductID: "luminavault_pro_monthly") == nil)
        #expect(SubscriptionCatalog.tier(forProductID: "") == nil)
    }

    /// Matching is exact, so a case variant is not the product we sell.
    @Test
    func `matching is case sensitive and exact`() {
        #expect(SubscriptionCatalog.tier(forProductID: "PRO_MONTHLY_14_99") == nil)
        #expect(SubscriptionCatalog.tier(forProductID: " pro_monthly_14_99") == nil)
    }

    @Test
    func `ids are unique and prices are the agreed ones`() {
        let ids = SubscriptionCatalog.products.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(SubscriptionCatalog.product(id: "pro_monthly_14_99")?.priceUSD == "14.99")
        #expect(SubscriptionCatalog.product(id: "pro_yearly_149_99")?.priceUSD == "149.99")
        #expect(SubscriptionCatalog.product(id: "ultimate_monthly_29_99")?.priceUSD == "29.99")
        #expect(SubscriptionCatalog.product(id: "ultimate_yearly_299_99")?.priceUSD == "299.99")
    }

    /// Only paid tiers are sellable — nothing may grant `lapsed` or `archived`.
    @Test
    func `every product grants a paid tier`() {
        for product in SubscriptionCatalog.products {
            #expect([UserTier.pro, .ultimate].contains(product.tier))
        }
    }
}
