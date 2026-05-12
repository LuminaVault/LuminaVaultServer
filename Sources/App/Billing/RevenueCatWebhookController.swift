import Crypto
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging

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
        case "INITIAL_PURCHASE", "PRODUCT_CHANGE":
            if let pid = event.productId {
                if pid.contains("ultimate") {
                    user.tier = "ultimate"
                } else if pid.contains("pro") {
                    user.tier = "pro"
                }
            }
            if let expMs = event.expirationAtMs {
                user.tierExpiresAt = Date(timeIntervalSince1970: TimeInterval(expMs) / 1000.0)
            }
        case "RENEWAL":
            if let expMs = event.expirationAtMs {
                user.tierExpiresAt = Date(timeIntervalSince1970: TimeInterval(expMs) / 1000.0)
            }
        case "CANCELLATION":
            if event.isRefund == true || (event.expirationAtMs ?? 0) < Int64(Date().timeIntervalSince1970 * 1000) {
                user.tier = "lapsed"
            }
        case "EXPIRATION":
            user.tier = "lapsed"
        case "BILLING_ISSUE":
            logger.info("billing issue reported for user", metadata: ["rc_user_id": .string(rcUserID)])
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
