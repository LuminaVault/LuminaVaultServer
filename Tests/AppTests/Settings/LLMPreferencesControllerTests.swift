@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-300 — `/v1/me/preferences/llm` GET/PUT including the
/// `mode` field that distinguishes managed default routing from BYOK.
@Suite(.serialized, .tags(.integration), .integrationDatabase)
struct LLMPreferencesControllerTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("llmpref-\(suffix)@test.luminavault", "llmpref-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodePrefs(_ buffer: ByteBuffer) throws -> LLMPreferencesGetResponse {
        try testJSONDecoder().decode(LLMPreferencesGetResponse.self, from: Data(buffer: buffer))
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!")
        ) { try decodeAuth($0.body) }
        return resp.accessToken
    }

    @Test
    func `get returns managed default when no row exists`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let prefs = try Self.decodePrefs(response.body)
                #expect(prefs.mode == .managed)
                #expect(prefs.fallbackChain.isEmpty)
                // HER-300/2: default surfaced to iOS must be the managed
                // OpenRouter route. Mirrors `hermes.defaultManagedModel`
                // (default `qwen/qwen-2.5-72b-instruct`).
                #expect(prefs.primaryProvider == .openRouter)
                #expect(prefs.primaryModel == "qwen/qwen-2.5-72b-instruct")
            }
        }
    }

    @Test
    func `put persists managed mode`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let body = ByteBuffer(string: """
            {"mode":"managed","primaryProvider":"openRouter","primaryModel":"qwen/qwen-2.5-72b-instruct","fallbackChain":[]}
            """)
            let put = try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body
            ) { response -> LLMPreferencesGetResponse in
                #expect(response.status == .ok)
                return try Self.decodePrefs(response.body)
            }
            #expect(put.mode == .managed)
            #expect(put.primaryModel == "qwen/qwen-2.5-72b-instruct")

            // Verify persistence via GET.
            let get = try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { try Self.decodePrefs($0.body) }
            #expect(get.mode == .managed)
            #expect(get.primaryModel == "qwen/qwen-2.5-72b-instruct")
        }
    }

    @Test
    func `put persists byok mode with explicit primary and fallback`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let body = ByteBuffer(string: """
            {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-7","fallbackChain":[{"provider":"openai","model":"gpt-4o"}]}
            """)
            let put = try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body
            ) { try Self.decodePrefs($0.body) }
            #expect(put.mode == .byok)
            #expect(put.primaryProvider == .anthropic)
            #expect(put.primaryModel == "claude-opus-4-7")
            #expect(put.fallbackChain.count == 1)
            #expect(put.fallbackChain[0].provider == .openai)
        }
    }

    @Test
    func `put without mode defaults to managed`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            // No `mode` key — back-compat path on the shared DTO defaults
            // it to `.managed`.
            let body = ByteBuffer(string: """
            {"primaryProvider":"openRouter","primaryModel":"qwen/qwen-2.5-72b-instruct","fallbackChain":[]}
            """)
            let put = try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body
            ) { try Self.decodePrefs($0.body) }
            #expect(put.mode == .managed)
        }
    }

    @Test
    func `unauthenticated returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/me/preferences/llm", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
