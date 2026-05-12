import FluentKit
import Foundation
import HummingbirdFluent
import Logging

// MARK: - RevenueCat webhook DTOs

/// Top-level wrapper that RevenueCat posts. The meaningful data lives
/// inside the nested `event` object.
struct RevenueCatWebhookPayload: Codable, Sendable {
    let event: RevenueCatWebhookEvent
}

/// Individual webhook event. RevenueCat sends snake_case JSON — the
/// custom `Decodable` init accepts both snake_case and camelCase keys
/// for resilience against format changes (same approach as StockPlan).
struct RevenueCatWebhookEvent: Codable, Sendable {
    let id: String
    let type: String
    let appUserId: String
    let productId: String?
    let periodType: String?
    let purchasedAtMs: Int64?
    let expirationAtMs: Int64?
    let gracePeriodExpiresDateMs: Int64?
    let cancelReason: String?
    let store: String?
    let originalTransactionId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case appUserId = "app_user_id"
        case appUserIdCamel = "appUserId"
        case productId = "product_id"
        case productIdCamel = "productId"
        case periodType = "period_type"
        case periodTypeCamel = "periodType"
        case purchasedAtMs = "purchased_at_ms"
        case purchasedAtMsCamel = "purchasedAtMs"
        case expirationAtMs = "expiration_at_ms"
        case expirationAtMsCamel = "expirationAtMs"
        case gracePeriodExpiresDateMs = "grace_period_expires_date_ms"
        case gracePeriodExpiresDateMsCamel = "gracePeriodExpiresDateMs"
        case cancelReason = "cancel_reason"
        case cancelReasonCamel = "cancelReason"
        case store
        case originalTransactionId = "original_transaction_id"
        case originalTransactionIdCamel = "originalTransactionId"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        appUserId = try c.decodeIfPresent(String.self, forKey: .appUserId)
            ?? c.decode(String.self, forKey: .appUserIdCamel)
        productId = try c.decodeIfPresent(String.self, forKey: .productId)
            ?? c.decodeIfPresent(String.self, forKey: .productIdCamel)
        periodType = try c.decodeIfPresent(String.self, forKey: .periodType)
            ?? c.decodeIfPresent(String.self, forKey: .periodTypeCamel)
        purchasedAtMs = try c.decodeIfPresent(Int64.self, forKey: .purchasedAtMs)
            ?? c.decodeIfPresent(Int64.self, forKey: .purchasedAtMsCamel)
        expirationAtMs = try c.decodeIfPresent(Int64.self, forKey: .expirationAtMs)
            ?? c.decodeIfPresent(Int64.self, forKey: .expirationAtMsCamel)
        gracePeriodExpiresDateMs = try c.decodeIfPresent(Int64.self, forKey: .gracePeriodExpiresDateMs)
            ?? c.decodeIfPresent(Int64.self, forKey: .gracePeriodExpiresDateMsCamel)
        cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
            ?? c.decodeIfPresent(String.self, forKey: .cancelReasonCamel)
        store = try c.decodeIfPresent(String.self, forKey: .store)
        originalTransactionId = try c.decodeIfPresent(String.self, forKey: .originalTransactionId)
            ?? c.decodeIfPresent(String.self, forKey: .originalTransactionIdCamel)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(appUserId, forKey: .appUserId)
        try c.encodeIfPresent(productId, forKey: .productId)
        try c.encodeIfPresent(periodType, forKey: .periodType)
        try c.encodeIfPresent(purchasedAtMs, forKey: .purchasedAtMs)
        try c.encodeIfPresent(expirationAtMs, forKey: .expirationAtMs)
        try c.encodeIfPresent(gracePeriodExpiresDateMs, forKey: .gracePeriodExpiresDateMs)
        try c.encodeIfPresent(cancelReason, forKey: .cancelReason)
        try c.encodeIfPresent(store, forKey: .store)
        try c.encodeIfPresent(originalTransactionId, forKey: .originalTransactionId)
    }
}

// MARK: - Billing service

/// Processes inbound RevenueCat webhook events and mutates `users.tier`
/// accordingly. Idempotent — duplicate `event.id` values are silently
/// ignored via a unique-constrained `billing_events` row.
///
/// Tier mapping (matches existing `UserTier` enum in `EntitlementChecker`):
///   INITIAL_PURCHASE / RENEWAL / UNCANCELLATION → `pro`
///   CANCELLATION → keep `pro`, set `tier_expires_at` to period end
///   EXPIRATION / REFUND → `lapsed`
///   BILLING_ISSUE → `pro` while grace period active, else `lapsed`
struct RevenueCatBillingService: Sendable {
    let fluent: Fluent
    let logger: Logger

    /// Process a single RevenueCat webhook event. Returns silently if the
    /// event has already been processed (idempotency).
    func process(event: RevenueCatWebhookEvent, rawPayload: String) async throws {
        let db = fluent.db()

        // ── 1. Idempotency check ────────────────────────────────────
        let existing = try await BillingEvent.query(on: db)
            .filter(\.$providerEventId == event.id)
            .first()
        if existing != nil {
            logger.info("duplicate billing event, skipping", metadata: [
                "event_id": .string(event.id),
                "type": .string(event.type),
            ])
            return
        }

        // ── 2. Log the event ────────────────────────────────────────
        let userId = UUID(uuidString: event.appUserId)
        let billingEvent = BillingEvent(
            providerEventId: event.id,
            eventType: event.type,
            userId: userId,
            rawPayload: rawPayload,
        )
        try await billingEvent.save(on: db)

        // ── 3. Resolve user ─────────────────────────────────────────
        guard let userId else {
            logger.warning("non-UUID app_user_id, cannot update tier", metadata: [
                "app_user_id": .string(event.appUserId),
            ])
            return
        }

        // Try revenuecat_user_id first, then fall back to primary key.
        var user: User? = try await User.query(on: db)
            .filter(\.$revenuecatUserID == event.appUserId)
            .first()
        if user == nil {
            user = try await User.find(userId, on: db)
        }

        guard let user else {
            logger.warning("user not found for billing event", metadata: [
                "user_id": .string(userId.uuidString),
                "event_type": .string(event.type),
            ])
            return
        }

        // Bind RC user id on first contact if absent.
        if user.revenuecatUserID == nil {
            user.revenuecatUserID = event.appUserId
        }

        // ── 4. Tier mutation ────────────────────────────────────────
        switch event.type {
        case "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION":
            user.tier = UserTier.pro.rawValue
            user.tierExpiresAt = event.expirationAtMs.map(Self.dateFromMs)

        case "CANCELLATION":
            // Keep pro until period_end — don't downgrade immediately.
            // tier_expires_at marks when the lapse-archiver cron should
            // flip to `lapsed`.
            user.tierExpiresAt = event.expirationAtMs.map(Self.dateFromMs)

        case "EXPIRATION", "REFUND":
            user.tier = UserTier.lapsed.rawValue
            user.tierExpiresAt = nil

        case "BILLING_ISSUE":
            let graceEnd = event.gracePeriodExpiresDateMs.map(Self.dateFromMs)
            let stillInGrace = graceEnd.map { $0 > Date() } ?? false
            if !stillInGrace {
                user.tier = UserTier.lapsed.rawValue
                user.tierExpiresAt = nil
            }
            // If still in grace, keep current tier unchanged.

        default:
            logger.debug("unhandled billing event type", metadata: [
                "type": .string(event.type),
            ])
            return
        }

        try await user.save(on: db)
        logger.info("user tier updated via billing webhook", metadata: [
            "user_id": .string(userId.uuidString),
            "event_type": .string(event.type),
            "new_tier": .string(user.tier),
        ])
    }

    // MARK: - Helpers

    private static func dateFromMs(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
