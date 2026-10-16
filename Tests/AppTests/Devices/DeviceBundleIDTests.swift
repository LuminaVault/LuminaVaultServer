@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// `POST /v1/devices` keeps the app's bundle id when the server may push to it
/// (the configured `apns.bundleId` or a `.beta` / `.test` variant) and drops a
/// foreign one, so a TestFlight build gets its own APNs topic.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct DeviceBundleIDTests {
    private static let configured = "com.lumina.fernando"

    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"device-\#(suffix)@test.luminavault","username":"device\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken }
    }

    private static func registerDevice(
        client: some TestClientProtocol,
        token: String,
        deviceToken: String,
        bundleId: String?
    ) async throws -> HTTPResponse.Status {
        let request = DeviceRegistrationRequest(token: deviceToken, platform: .ios, bundleId: bundleId)
        return try await client.execute(
            uri: "/v1/devices",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: JSONEncoder().encode(request))
        ) { $0.status }
    }

    private static func storedBundleID(_ deviceToken: String) async throws -> String? {
        try await withTestFluent(label: "test.devices.bundle") { fluent in
            try #require(try await DeviceToken.query(on: fluent.db()).filter(\.$token == deviceToken).first()).bundleID
        }
    }

    @Test
    func `stores an allowed bundle id and drops a foreign one`() async throws {
        let app = try await buildApplication(reader: dbTestReader(overriding: ["apns.bundleId": cfg(Self.configured)]))
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let beta = "beta-\(UUID().uuidString)"
            let prod = "prod-\(UUID().uuidString)"
            let foreign = "foreign-\(UUID().uuidString)"
            let legacy = "legacy-\(UUID().uuidString)"

            #expect(try await Self.registerDevice(client: client, token: token, deviceToken: beta, bundleId: "com.lumina.fernando.beta") == .ok)
            #expect(try await Self.registerDevice(client: client, token: token, deviceToken: prod, bundleId: Self.configured) == .ok)
            #expect(try await Self.registerDevice(client: client, token: token, deviceToken: foreign, bundleId: "com.lumina.fernandox") == .ok)
            #expect(try await Self.registerDevice(client: client, token: token, deviceToken: legacy, bundleId: nil) == .ok)

            #expect(try await Self.storedBundleID(beta) == "com.lumina.fernando.beta")
            #expect(try await Self.storedBundleID(prod) == Self.configured)
            #expect(try await Self.storedBundleID(foreign) == nil)
            #expect(try await Self.storedBundleID(legacy) == nil)

            // An older client re-registering without a bundle id keeps the stored one.
            #expect(try await Self.registerDevice(client: client, token: token, deviceToken: beta, bundleId: nil) == .ok)
            #expect(try await Self.storedBundleID(beta) == "com.lumina.fernando.beta")
        }
    }

    @Test
    func `allowed bundle ids are the configured one and its variants`() {
        #expect(APNSNotificationService.isAllowedBundleID("com.lumina.fernando", configured: Self.configured))
        #expect(APNSNotificationService.isAllowedBundleID("com.lumina.fernando.beta", configured: Self.configured))
        #expect(APNSNotificationService.isAllowedBundleID("com.lumina.fernando.test", configured: Self.configured))
        #expect(!APNSNotificationService.isAllowedBundleID("com.lumina.fernandox", configured: Self.configured))
        #expect(!APNSNotificationService.isAllowedBundleID("com.other.app", configured: Self.configured))
        #expect(!APNSNotificationService.isAllowedBundleID("com.lumina.fernando.beta", configured: ""))
        #expect(APNSNotificationService.topic(for: nil, configured: Self.configured) == Self.configured)
        #expect(APNSNotificationService.topic(for: "com.other.app", configured: Self.configured) == Self.configured)
        #expect(APNSNotificationService.topic(for: "com.lumina.fernando.beta", configured: Self.configured) == "com.lumina.fernando.beta")
    }
}
