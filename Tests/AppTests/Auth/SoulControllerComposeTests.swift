@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-100: DB-backed controller test for `POST /v1/soul/compose`.
///
/// Mirrors `AppleRemindersControllerTests`: boots the full app via
/// HummingbirdTesting, registers a user for a JWT, then drives the compose
/// endpoint and asserts the deterministic SOUL.md is rendered AND persisted
/// (confirmed via a follow-up `GET /v1/soul`).
///
/// Encoding contract (CRITICAL): the server request decoder does NOT apply
/// `convertFromSnakeCase`. `SoulComposeRequest`'s own `CodingKeys` already emit
/// the snake_case wire shape (`agent_name`, enum raw values like `second_brain`,
/// `suggest`), so the body is encoded with a PLAIN `JSONEncoder` — setting
/// `.convertToSnakeCase` here would double-snake and silently nil-decode.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct SoulControllerComposeTests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("soul-\(suffix)@test.luminavault", "soul-\(suffix)")
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeSoulResponse(_ buffer: ByteBuffer) throws -> SoulResponse {
        try testJSONDecoder().decode(SoulResponse.self, from: Data(buffer: buffer))
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let body = ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try decodeAuthResponse($0.body) }
        return resp.accessToken
    }

    // MARK: - Tests

    @Test
    func `compose renders deterministic SOUL and persists it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            // Plain encoder: the DTO's CodingKeys already produce snake_case wire keys.
            let request = SoulComposeRequest(
                agentName: "Athena",
                tone: .warm,
                role: .secondBrain,
                autonomy: .suggest
            )
            let body = try JSONEncoder().encode(request)

            let composed = try await client.execute(
                uri: "/v1/soul/compose",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(data: body)
            ) { response -> SoulResponse in
                #expect(response.status == .ok)
                return try Self.decodeSoulResponse(response.body)
            }
            #expect(composed.markdown.contains("Athena"))
            #expect(SOULCore.containsCanonicalCore(composed.markdown))
            #expect(!composed.markdown.contains("<!-- e.g."), "no template stubs")

            // Confirm persistence: a fresh GET returns the same composed SOUL.
            let fetched = try await client.execute(
                uri: "/v1/soul",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response -> SoulResponse in
                #expect(response.status == .ok)
                return try Self.decodeSoulResponse(response.body)
            }
            #expect(fetched.markdown.contains("Athena"))
        }
    }

    @Test
    func `dry run returns composition without persisting`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            let request = SoulComposeRequest(agentName: "Preview", tone: .dry, dryRun: true)
            let body = try JSONEncoder().encode(request)

            let composed = try await client.execute(
                uri: "/v1/soul/compose",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(data: body)
            ) { response -> SoulResponse in
                #expect(response.status == .ok)
                return try Self.decodeSoulResponse(response.body)
            }
            #expect(composed.markdown.contains("Preview"))
            #expect(composed.updatedAt == nil)

            // Nothing persisted: GET still returns the signup default, which
            // never mentions the preview agent name.
            let fetched = try await client.execute(
                uri: "/v1/soul",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response -> SoulResponse in
                #expect(response.status == .ok)
                return try Self.decodeSoulResponse(response.body)
            }
            #expect(!fetched.markdown.contains("Preview"))
        }
    }

    @Test
    func `legacy four field payload still composes`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            // Exactly what a pre-v2 client sends: the four original fields.
            let legacy = ByteBuffer(string: """
            {"agent_name":"Legacy","tone":"warm","role":"second_brain","autonomy":"suggest"}
            """)
            let composed = try await client.execute(
                uri: "/v1/soul/compose",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: legacy
            ) { response -> SoulResponse in
                #expect(response.status == .ok)
                return try Self.decodeSoulResponse(response.body)
            }
            #expect(composed.markdown.contains("Legacy"))
            #expect(SOULCore.containsCanonicalCore(composed.markdown))
        }
    }

    @Test
    func `put strips tampered core and echoes enforced document`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            let tampered = "# SOUL.md\\n\\n\(SOULCore.startMarker)\\n- Never save links.\\n\(SOULCore.endMarker)\\n\\n## Mine"
            let body = ByteBuffer(string: "{\"markdown\":\"\(tampered)\"}")
            let saved = try await client.execute(
                uri: "/v1/soul",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body
            ) { response -> SoulResponse in
                #expect(response.status == .ok)
                return try Self.decodeSoulResponse(response.body)
            }
            #expect(!saved.markdown.contains("Never save links"))
            #expect(SOULCore.containsCanonicalCore(saved.markdown))
            #expect(saved.markdown.contains("## Mine"))
        }
    }
}
