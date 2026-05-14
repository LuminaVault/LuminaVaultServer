@testable import App
import Configuration
import Crypto
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

@Suite(.serialized)
struct RevenueCatWebhookTests {
    private static let webhookSecret = "test-rc-webhook-secret-32-chars-min"
    private static let password = "CorrectHorseBatteryStaple1!"

    private static func reader() -> ConfigReader {
        ConfigReader(providers: [
            InMemoryProvider(values: [
                "http.host": cfg("127.0.0.1"),
                "http.port": cfg(0),
                "log.level": cfg("warning"),
                "postgres.host": cfg(TestPostgres.host),
                "postgres.port": cfg(TestPostgres.port),
                "postgres.database": cfg(TestPostgres.database),
                "postgres.user": cfg(TestPostgres.username),
                "postgres.password": cfg(TestPostgres.password),
                "fluent.autoMigrate": cfg("true"),
                "jwt.hmac.secret": cfg("test-secret-do-not-use-in-prod-32chars"),
                "jwt.kid": cfg("test-kid"),
                "hermes.gatewayKind": cfg("logging"),
                "hermes.dataRoot": cfg("/tmp/luminavault-test-hermes"),
                "vault.rootPath": cfg("/tmp/luminavault-test"),
                "revenuecat.webhookSecret": cfg(webhookSecret),
            ]),
        ])
    }

    private static func randomUser(prefix: String) -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("\(prefix)-\(suffix)@test.luminavault", "\(prefix)-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let user = randomUser(prefix: "rc")
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"email":"\#(user.email)","username":"\#(user.username)","password":"\#(password)"}"#),
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
    }

    private static func bindRevenueCatID(userID: UUID, rcUserID: String) async throws {
        try await withTestFluent(label: "test.rc-webhook.bind") { fluent in
            let user = try #require(try await User.find(userID, on: fluent.db()))
            user.revenuecatUserID = rcUserID
            try await user.save(on: fluent.db())
        }
    }

    private static func loadUser(userID: UUID) async throws -> User {
        try await withTestFluent(label: "test.rc-webhook.load") { fluent in
            try #require(try await User.find(userID, on: fluent.db()))
        }
    }

    private static func eventLogCount(eventID: String) async throws -> Int {
        try await withTestFluent(label: "test.rc-webhook.eventlog") { fluent in
            try await BillingEventLog.query(on: fluent.db()).filter(\.$eventID == eventID).count()
        }
    }

    private static func signedHeaders(body: String) -> HTTPFields {
        let key = SymmetricKey(data: Data(webhookSecret.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        let sig = Data(hmac).map { String(format: "%02hhx", $0) }.joined()
        var headers: HTTPFields = [.contentType: "application/json"]
        headers[HTTPField.Name("X-RevenueCat-Signature")!] = sig
        return headers
    }

    private static func bearerHeaders() -> HTTPFields {
        [.authorization: "Bearer \(webhookSecret)", .contentType: "application/json"]
    }

    private static func payload(
        eventID: String,
        type: String,
        appUserId: String,
        productId: String? = nil,
        expirationAtMs: Int64? = nil,
        isRefund: Bool? = nil,
    ) -> String {
        var parts: [String] = [
            "\"id\":\"\(eventID)\"",
            "\"type\":\"\(type)\"",
            "\"app_user_id\":\"\(appUserId)\"",
        ]
        if let productId { parts.append("\"product_id\":\"\(productId)\"") }
        if let expirationAtMs { parts.append("\"expiration_at_ms\":\(expirationAtMs)") }
        if let isRefund { parts.append("\"is_refund\":\(isRefund)") }
        return "{\"event\":{\(parts.joined(separator: ","))}}"
    }

    @Test
    func `bad signature returns 401`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.bindRevenueCatID(userID: auth.userId, rcUserID: auth.userId.uuidString)

            let body = Self.payload(eventID: "evt-bad-sig-1", type: "INITIAL_PURCHASE", appUserId: auth.userId.uuidString)
            var headers: HTTPFields = [.contentType: "application/json"]
            headers[HTTPField.Name("X-RevenueCat-Signature")!] = "deadbeef"

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `initial purchase upgrades tier to pro and sets expiry`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.bindRevenueCatID(userID: auth.userId, rcUserID: auth.userId.uuidString)

            let futureMs = Int64(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000)
            let body = Self.payload(
                eventID: "evt-init-\(UUID().uuidString)",
                type: "INITIAL_PURCHASE",
                appUserId: auth.userId.uuidString,
                productId: "luminavault_pro_monthly",
                expirationAtMs: futureMs,
            )

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.signedHeaders(body: body),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }

            let user = try await Self.loadUser(userID: auth.userId)
            #expect(user.tier == "pro")
            #expect(user.tierExpiresAt != nil)
        }
    }

    @Test
    func `initial purchase ultimate sets ultimate tier`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.bindRevenueCatID(userID: auth.userId, rcUserID: auth.userId.uuidString)

            let body = Self.payload(
                eventID: "evt-ult-\(UUID().uuidString)",
                type: "INITIAL_PURCHASE",
                appUserId: auth.userId.uuidString,
                productId: "luminavault_ultimate_annual",
                expirationAtMs: Int64(Date().addingTimeInterval(86400 * 365).timeIntervalSince1970 * 1000),
            )

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.signedHeaders(body: body),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }

            let user = try await Self.loadUser(userID: auth.userId)
            #expect(user.tier == "ultimate")
        }
    }

    @Test
    func `expiration drops tier to lapsed`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.bindRevenueCatID(userID: auth.userId, rcUserID: auth.userId.uuidString)

            let body = Self.payload(
                eventID: "evt-exp-\(UUID().uuidString)",
                type: "EXPIRATION",
                appUserId: auth.userId.uuidString,
            )

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.signedHeaders(body: body),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }

            let user = try await Self.loadUser(userID: auth.userId)
            #expect(user.tier == "lapsed")
        }
    }

    @Test
    func `replayed event id is idempotent (200 plus no duplicate row)`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.bindRevenueCatID(userID: auth.userId, rcUserID: auth.userId.uuidString)

            let eventID = "evt-replay-\(UUID().uuidString)"
            let body = Self.payload(
                eventID: eventID,
                type: "INITIAL_PURCHASE",
                appUserId: auth.userId.uuidString,
                productId: "luminavault_pro_monthly",
                expirationAtMs: Int64(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000),
            )

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.signedHeaders(body: body),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.signedHeaders(body: body),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }

            let count = try await Self.eventLogCount(eventID: eventID)
            #expect(count == 1)
        }
    }

    @Test
    func `unknown rc user id returns 200 (sub-before-signup race)`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let unknown = UUID().uuidString
            let body = Self.payload(
                eventID: "evt-unknown-\(UUID().uuidString)",
                type: "RENEWAL",
                appUserId: unknown,
                expirationAtMs: Int64(Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000),
            )

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.signedHeaders(body: body),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `bearer auth header accepted as alternative to hmac signature`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.bindRevenueCatID(userID: auth.userId, rcUserID: auth.userId.uuidString)

            let body = Self.payload(
                eventID: "evt-bearer-\(UUID().uuidString)",
                type: "RENEWAL",
                appUserId: auth.userId.uuidString,
                expirationAtMs: Int64(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000),
            )

            try await client.execute(
                uri: "/v1/billing/revenuecat-webhook",
                method: .post,
                headers: Self.bearerHeaders(),
                body: ByteBuffer(string: body),
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
