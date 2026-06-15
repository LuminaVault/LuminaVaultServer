@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import Testing

/// HER-240c — `PremiumGuardMiddleware` HTTP-level gate.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct PremiumGuardMiddlewareTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("pg-\(suffix)@test.luminavault", "pg-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = Self.randomUser()
        let body = ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { response in
            let decoded = try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
            return decoded.accessToken
        }
    }

    @Test
    func `trial user hits 402 on grok routes`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/grok/chat",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"messages":[{"role":"user","content":"hi"}]}"#)
            ) { response in
                #expect(response.status.code == 402)
                let bodyText = String(buffer: response.body)
                #expect(bodyText.contains("requiresXaiConnect"))
            }
        }
    }

    @Test
    func `unauthenticated request returns 401 before reaching premium guard`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/grok/chat",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"messages":[]}"#)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
