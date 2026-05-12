@testable import App
import Configuration
import FluentKit
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@Suite(.serialized)
struct EnforcementTests {
    private static let password = "CorrectHorseBatteryStaple1!"

    private static func reader(enforcementEnabled: Bool, adminToken: String = "billing-admin") -> ConfigReader {
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
                "billing.enforcementEnabled": cfg(enforcementEnabled ? "true" : "false"),
                "admin.token": cfg(adminToken),
            ]),
        ])
    }

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: #"{"email":"\#(email)","username":"\#(username)","password":"\#(password)"}"#)
    }

    private static func healthBody() -> ByteBuffer {
        ByteBuffer(string: """
        {"events":[{"type":"steps","recordedAt":"2026-05-12T12:00:00Z","valueNumeric":12,"valueText":null,"unit":"count","source":"test","metadata":null}]}
        """)
    }

    private static func randomUser(prefix: String) -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("\(prefix)-\(suffix)@test.luminavault", "\(prefix)-\(suffix)")
    }

    private static func register(client: some TestClientProtocol, prefix: String = "billing") async throws -> AuthResponse {
        let user = randomUser(prefix: prefix)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: user.email, username: user.username),
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
    }

    private static func setBillingState(userID: UUID, tier: UserTier, override: TierOverride = .none) async throws {
        try await withTestFluent(label: "test.billing.enforcement") { fluent in
            let user = try #require(try await User.find(userID, on: fluent.db()))
            user.tier = tier.rawValue
            user.tierOverride = override.rawValue
            try await user.save(on: fluent.db())
        }
    }

    @Test
    func `enforcement disabled is middleware no op for lapsed user`() async throws {
        let app = try await buildApplication(reader: Self.reader(enforcementEnabled: false))
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.setBillingState(userID: auth.userId, tier: .lapsed)

            try await client.execute(
                uri: "/v1/health",
                method: .post,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: Self.healthBody(),
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `enforcement enabled returns default paywall for insufficient pro gate`() async throws {
        let app = try await buildApplication(reader: Self.reader(enforcementEnabled: true))
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.setBillingState(userID: auth.userId, tier: .lapsed)

            try await client.execute(
                uri: "/v1/health",
                method: .post,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: Self.healthBody(),
            ) { response in
                #expect(response.status.code == 402)
                let paywall = try testJSONDecoder().decode(PaywallResponse.self, from: Data(buffer: response.body))
                #expect(paywall.paywall)
                #expect(paywall.paywallId == "default")
            }
        }
    }

    @Test
    func `ultimate only capability returns upsell paywall hint`() throws {
        #expect(EntitlementMiddleware.paywallID(for: .skillVaultRun) == "ultimate_upsell")
        #expect(EntitlementMiddleware.paywallID(for: .privacyBYOKey) == "ultimate_upsell")
        #expect(EntitlementMiddleware.paywallID(for: .healthIngest) == "default")
    }

    @Test
    func `ultimate override wins even when stored tier is lapsed`() async throws {
        let app = try await buildApplication(reader: Self.reader(enforcementEnabled: true))
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.setBillingState(userID: auth.userId, tier: .lapsed, override: .ultimate)

            try await client.execute(
                uri: "/v1/health",
                method: .post,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: Self.healthBody(),
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `vault export remains available to lapsed user`() async throws {
        let app = try await buildApplication(reader: Self.reader(enforcementEnabled: true))
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.setBillingState(userID: auth.userId, tier: .lapsed)

            try await client.execute(
                uri: "/v1/vault/export",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `admin can set tier override`() async throws {
        let token = "billing-admin-\(UUID().uuidString)"
        let app = try await buildApplication(reader: Self.reader(enforcementEnabled: false, adminToken: token))
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            try await client.execute(
                uri: "/v1/admin/users/\(auth.userId.uuidString)/tier-override",
                method: .put,
                headers: [.init("x-admin-token")!: token, .contentType: "application/json"],
                body: ByteBuffer(string: #"{"tierOverride":"ultimate"}"#),
            ) { response in
                #expect(response.status == .ok)
                let summary = try testJSONDecoder().decode(UserBillingSummary.self, from: Data(buffer: response.body))
                #expect(summary.id == auth.userId)
                #expect(summary.tierOverride == "ultimate")
            }
        }
    }

    @Test
    func `admin tier override rejects invalid enum`() async throws {
        let token = "billing-admin-\(UUID().uuidString)"
        let app = try await buildApplication(reader: Self.reader(enforcementEnabled: false, adminToken: token))
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            try await client.execute(
                uri: "/v1/admin/users/\(auth.userId.uuidString)/tier-override",
                method: .put,
                headers: [.init("x-admin-token")!: token, .contentType: "application/json"],
                body: ByteBuffer(string: #"{"tierOverride":"godmode"}"#),
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
