@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// BYOK tier parity and fail-closed missing-key behaviour.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct BYOKConsistencyTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("byok-\(suffix)@test.luminavault", "byok-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
            """)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
        return resp.accessToken
    }

    private static func decodeProfiles(_ buffer: ByteBuffer) throws -> RouterProfilesResponse {
        try testJSONDecoder().decode(RouterProfilesResponse.self, from: Data(buffer: buffer))
    }

    private static func writeRequest(from profile: RouterProfileDTO, mode: LLMBrainMode) -> RouterProfileWriteRequest {
        RouterProfileWriteRequest(
            name: profile.name,
            mode: mode,
            objective: profile.objective,
            budget: profile.budget,
            allowedProviders: profile.allowedProviders,
            blockedProviders: profile.blockedProviders,
            defaultAction: profile.defaultAction,
            rules: profile.rules,
            routingPolicy: profile.routingPolicy,
            expectedRevision: profile.revision
        )
    }

    @Test
    func `trial user can set default router profile to byok`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let profiles = try await client.execute(
                uri: "/v1/router",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { try Self.decodeProfiles($0.body) }
            let active = try #require(profiles.profiles.first { $0.id == profiles.defaultProfileID })
            let body = Self.writeRequest(from: active, mode: .byok)
            let encoded = try testJSONEncoder().encode(body)
            try await client.execute(
                uri: "/v1/router/\(active.id.uuidString)",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(data: encoded)
            ) { response in
                #expect(response.status == .ok)
                let updated = try testJSONDecoder().decode(RouterProfileDTO.self, from: Data(buffer: response.body))
                #expect(updated.mode == .byok)
            }
        }
    }

    @Test
    func `byok chat without provider keys returns byok_keys_required`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: """
                {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-7","fallbackChain":[]}
                """)
            ) { response in
                #expect(response.status == .ok)
            }

            try await client.execute(
                uri: "/v1/llm/chat",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: """
                {"messages":[{"role":"user","content":"Hello"}]}
                """)
            ) { response in
                #expect(response.status == .forbidden)
                let json = try #require(
                    JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                )
                let error = try #require(json["error"] as? [String: Any])
                #expect(error["code"] as? String == "byok_keys_required")
                #expect((error["message"] as? String)?.isEmpty == false)
                let cta = try #require(error["cta"] as? [String])
                #expect(cta.contains("add_key"))
                #expect(cta.contains("switch_to_managed"))
            }
        }
    }
}
