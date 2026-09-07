import Crypto
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

struct RevenueCatWebhookController {
    let fluent: Fluent
    let webhookSecret: String
    let logger: Logger

    init(fluent: Fluent, webhookSecret: String, logger: Logger = Logger(label: "lv.billing.revenuecat-webhook")) {
        self.fluent = fluent
        self.webhookSecret = webhookSecret
        self.logger = logger
    }

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("/revenuecat-webhook", use: handleWebhook)
    }

    @Sendable
    func handleWebhook(request: Request, context _: AppRequestContext) async throws -> HTTPResponse.Status {
        guard !webhookSecret.isEmpty else {
            logger.error("webhook secret not configured")
            throw HTTPError(.internalServerError)
        }

        let buffer = try await request.body.collect(upTo: 1024 * 1024)
        let bodyData = Data(buffer: buffer)

        let authHeader = request.headers[.authorization]?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let rcSignatureHeaderName = HTTPField.Name("X-RevenueCat-Signature")!
        let rcSignature = request.headers[rcSignatureHeaderName] ?? ""

        let key = SymmetricKey(data: Data(webhookSecret.utf8))
        var isValidHMAC = false

        if !authHeader.isEmpty {
            isValidHMAC = constantTimeEquals(authHeader, webhookSecret)
        }
        if !isValidHMAC, !rcSignature.isEmpty {
            let computed = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
            let computedHex = Data(computed).map { String(format: "%02hhx", $0) }.joined()
            isValidHMAC = constantTimeEquals(computedHex, rcSignature)
        }

        guard isValidHMAC else {
            logger.warning("invalid webhook signature")
            throw HTTPError(.unauthorized)
        }

        let payload: RCWebhookPayload
        do {
            payload = try JSONDecoder().decode(RCWebhookPayload.self, from: bodyData)
        } catch {
            logger.error("failed to decode webhook payload", metadata: ["error": .string("\(error)")])
            throw HTTPError(.badRequest)
        }

        let event = payload.event

        if try await BillingEventLog.query(on: fluent.db()).filter(\.$eventID == event.id).first() != nil {
            logger.info("webhook event already processed", metadata: ["event_id": .string(event.id)])
            return .ok
        }

        let resolvedUserID = try await processEvent(event)

        let log = BillingEventLog(eventID: event.id, eventType: event.type, userID: resolvedUserID)
        try await log.create(on: fluent.db())

        return .ok
    }

    /// How long a `BILLING_ISSUE` holds the tier. Apple retries a failed
    /// charge for up to ~16 days; this covers it without holding forever.
    static let billingRetryGrace: TimeInterval = 16 * 24 * 60 * 60

    /// Thrown when RevenueCat reports a purchase of something we do not sell.
    ///
    /// Deliberately an error rather than a shrug: the handler must not write a
    /// `billing_event_logs` row for it, because that row would suppress the
    /// retry and strand a paying user on the wrong tier permanently.
    struct UnknownProductError: Error, CustomStringConvertible {
        let productID: String?
        var description: String {
            "unmapped RevenueCat product: \(productID ?? "<none>")"
        }
    }

    /// Grants the tier a paid event entitles the user to.
    private func applyPurchase(event: RCEvent, to user: User) throws {
        guard let productID = event.productId, let tier = SubscriptionCatalog.tier(forProductID: productID) else {
            logger.error("revenuecat reported a product we do not sell", metadata: [
                "product_id": .string(event.productId ?? "<none>"),
                "event_type": .string(event.type),
                "known": .string(SubscriptionCatalog.products.map(\.id).joined(separator: ",")),
            ])
            throw UnknownProductError(productID: event.productId)
        }
        user.tier = tier.rawValue
        if let expMs = event.expirationAtMs {
            user.tierExpiresAt = Date(timeIntervalSince1970: TimeInterval(expMs) / 1000.0)
        }
    }

    /// Returns the resolved user UUID when the event mapped to a user, nil otherwise.
    private func processEvent(_ event: RCEvent) async throws -> UUID? {
        let rcUserID = event.appUserId
        let user = try await User.query(on: fluent.db())
            .group(.or) { group in
                group.filter(\.$revenuecatUserID == rcUserID)
                if let uuid = UUID(uuidString: rcUserID) {
                    group.filter(\.$id == uuid)
                }
            }
            .first()

        guard let user else {
            logger.warning("user not found for revenuecat_user_id", metadata: ["rc_user_id": .string(rcUserID)])
            return nil
        }

        user.revenuecatUserID = rcUserID

        switch event.type {
        case "INITIAL_PURCHASE", "PRODUCT_CHANGE", "RENEWAL", "UNCANCELLATION":
            // RENEWAL used to write only the expiry. A subscriber who had
            // already been flipped to `lapsed` — by a *missed* earlier renewal
            // — therefore renewed successfully, got a future expiry, and stayed
            // locked out, because nothing restored the tier. Granting on every
            // paid event fixes that and is idempotent.
            try applyPurchase(event: event, to: user)
        case "CANCELLATION":
            // Cancellation is a statement about auto-renew, not about access:
            // the user keeps what they paid for until the period ends. Only a
            // refund or an already-past expiry ends it now.
            if event.isRefund == true || (event.expirationAtMs ?? 0) < Int64(Date().timeIntervalSince1970 * 1000) {
                user.tier = UserTier.lapsed.rawValue
            }
        case "EXPIRATION":
            user.tier = UserTier.lapsed.rawValue
        case "BILLING_ISSUE":
            // Apple retries a failed charge for days. Demoting on the first
            // failure would lock out a user whose card is about to succeed, so
            // hold the tier and push the expiry into the retry window — the
            // nightly lapse job reads that expiry and would otherwise demote
            // them tonight.
            let hold = Date().addingTimeInterval(Self.billingRetryGrace)
            if (user.tierExpiresAt ?? .distantPast) < hold {
                user.tierExpiresAt = hold
            }
            logger.warning("billing issue — holding tier through the retry window", metadata: [
                "rc_user_id": .string(rcUserID),
                "tier": .string(user.tier),
                "hold_until": .string(ISO8601DateFormatter().string(from: hold)),
            ])
        case "SUBSCRIBER_ALIAS":
            logger.info("subscriber alias event", metadata: ["rc_user_id": .string(rcUserID)])
        default:
            logger.info("unhandled event type", metadata: ["type": .string(event.type)])
        }

        try await user.save(on: fluent.db())
        return user.id
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

struct RCWebhookPayload: Codable {
    let event: RCEvent
}

struct RCEvent: Codable {
    let id: String
    let type: String
    let appUserId: String
    let expirationAtMs: Int64?
    let productId: String?
    let isRefund: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case appUserId = "app_user_id"
        case expirationAtMs = "expiration_at_ms"
        case productId = "product_id"
        case isRefund = "is_refund"
    }
}
