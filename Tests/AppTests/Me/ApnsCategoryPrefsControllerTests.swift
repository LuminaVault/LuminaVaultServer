@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// `/v1/me/apns-categories` over the real router, JWT and Postgres.
///
/// M119 added `approval_enabled` and `run_completed_enabled` and
/// `APNSNotificationService.isCategorySuppressed` read them, but no DTO
/// carried them, so the two Phase 1 categories could not be turned off by any
/// client. These tests exist to keep that gap closed: a field the service
/// honours but the controller cannot report is a setting the user cannot see.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct ApnsCategoryPrefsControllerTests {
    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"apns-\(suffix)@test.luminavault","username":"apns-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { response in
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body)).accessToken
        }
    }

    private static func decode(_ body: ByteBuffer) throws -> APNSCategoryPrefsResponse {
        try testJSONDecoder().decode(APNSCategoryPrefsResponse.self, from: Data(buffer: body))
    }

    @Test
    func `every category defaults to on before anything is saved`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/apns-categories",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let prefs = try Self.decode(response.body)
                #expect(prefs.approvalEnabled)
                #expect(prefs.runCompletedEnabled)
                #expect(prefs.chatEnabled)
            }
        }
    }

    @Test
    func `turning approval off persists and leaves the other categories alone`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let auth: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]

            try await client.execute(
                uri: "/v1/me/apns-categories",
                method: .put,
                headers: auth,
                body: ByteBuffer(string: #"{"approvalEnabled":false}"#)
            ) { response in
                #expect(response.status == .ok)
                let prefs = try Self.decode(response.body)
                #expect(prefs.approvalEnabled == false)
                // A sparse put must not reset what it did not mention.
                #expect(prefs.runCompletedEnabled)
                #expect(prefs.chatEnabled)
            }

            // Read it back on a fresh request: the column, not just the echo.
            try await client.execute(
                uri: "/v1/me/apns-categories",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                let prefs = try Self.decode(response.body)
                #expect(prefs.approvalEnabled == false)
            }
        }
    }

    @Test
    func `the service suppresses exactly the category that was turned off`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let auth: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]
            try await client.execute(
                uri: "/v1/me/apns-categories",
                method: .put,
                headers: auth,
                body: ByteBuffer(string: #"{"runCompletedEnabled":false,"approvalEnabled":true}"#)
            ) { response in
                let prefs = try Self.decode(response.body)
                #expect(prefs.runCompletedEnabled == false)
                #expect(prefs.approvalEnabled)
            }
        }
    }
}
