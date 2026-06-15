@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import SQLKit
import Testing

/// HER-240c — `GrokController` route shape + premium-guard interaction.
/// Real upstream Hermes traffic is NOT exercised here (no live container
/// running in tests); the controller surface is checked end-to-end as
/// 402 / 409 paths only. Upstream success path is covered by
/// `HermesGrokProxy` unit tests in a follow-up commit.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct GrokControllerTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("gc-\(suffix)@test.luminavault", "gc-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> (token: String, userID: UUID) {
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
            return (decoded.accessToken, decoded.userId)
        }
    }

    /// Promote the user's tier directly via SQL — we don't have a live
    /// xai-oauth flow inside these tests, only need the premium guard to
    /// let traffic through.
    private static func promoteToPro(userID: UUID) async throws {
        try await withTestFluent(label: "lv.test.her240c.gc") { fluent in
            guard let sql = fluent.db() as? any SQLDatabase else { return }
            try await sql.raw("""
            UPDATE users SET tier = 'pro' WHERE id = \(bind: userID)
            """).run()
        }
    }

    @Test
    func `premium user with no xai container hits 409 conflict`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, userID) = try await Self.register(client: client)
            try await Self.promoteToPro(userID: userID)

            try await client.execute(
                uri: "/v1/grok/chat",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"messages":[{"role":"user","content":"hi"}]}"#)
            ) { response in
                #expect(response.status.code == 409, "premium without xai must surface as 409 reconnect prompt")
                #expect(String(buffer: response.body).contains("xai_not_connected"))
            }
        }
    }

    @Test
    func `x-search rejects empty query with 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, userID) = try await Self.register(client: client)
            try await Self.promoteToPro(userID: userID)

            try await client.execute(
                uri: "/v1/grok/x-search",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"query":""}"#)
            ) { response in
                #expect(response.status.code == 400)
            }
        }
    }

    @Test
    func `vision rejects empty imageURLs with 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, userID) = try await Self.register(client: client)
            try await Self.promoteToPro(userID: userID)

            try await client.execute(
                uri: "/v1/grok/vision",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"prompt":"describe","imageURLs":[]}"#)
            ) { response in
                #expect(response.status.code == 400)
            }
        }
    }

    @Test
    func `tts returns 501 while upstream provider is disabled`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, userID) = try await Self.register(client: client)
            try await Self.promoteToPro(userID: userID)

            try await client.execute(
                uri: "/v1/grok/tts",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"text":"hello"}"#)
            ) { response in
                #expect(response.status.code == 501)
                #expect(String(buffer: response.body).contains("tts_coming_soon"))
            }
        }
    }
}
