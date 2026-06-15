@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-300 — end-to-end coverage for the "Use LuminaVault Default" path that
/// 500'd in onboarding: a user signs up, signs in, sets a managed-brain LLM
/// preference, and chats — getting a reply.
///
/// The regression this guards is real: `UserLLMPreference.fallbackChain` was a
/// bare `[FallbackStep]`, which FluentPostgres binds as `jsonb[]` while the
/// `M47` column is a single `jsonb` — so every `PUT /v1/me/preferences/llm`
/// failed with `preference_save_failed`. Step 3 below pins it to 200.
///
/// Built with `dbTestReaderWithStubChat()` so the chat hop resolves to the
/// deterministic `StubChatAdapter` (no network). Requires
/// `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct LLMPreferencesChatE2ETests {
    // MARK: - Helpers

    private static let stubReply = "Hello from the LuminaVault default brain."
    private static let password = "CorrectHorseBatteryStaple1!"

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("llm-e2e-\(suffix)@test.luminavault", "llm-e2e-\(suffix)")
    }

    private static func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func decodePrefs(_ buf: ByteBuffer) throws -> LLMPreferencesGetResponse {
        try testJSONDecoder().decode(LLMPreferencesGetResponse.self, from: Data(buffer: buf))
    }

    private static func decodeChat(_ buf: ByteBuffer) throws -> ChatResponse {
        try testJSONDecoder().decode(ChatResponse.self, from: Data(buffer: buf))
    }

    /// Register a fresh user over HTTP, then log in with the same credentials.
    /// Returns the access token from the login response so the test exercises
    /// the full signup → signin flow rather than reusing the register token.
    private static func signUpThenSignIn(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","username":"\(username)","password":"\(password)"}
            """)
        ) { resp in
            #expect(resp.status == .ok)
        }
        return try await client.execute(
            uri: "/v1/auth/login",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","password":"\(password)"}
            """)
        ) { resp in
            #expect(resp.status == .ok)
            let auth = try decodeAuth(resp.body)
            #expect(!auth.accessToken.isEmpty)
            return auth.accessToken
        }
    }

    // MARK: - Tests

    @Test
    func `signup, signin, set managed brain, then chat gets a reply`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat(replyContent: Self.stubReply))
        try await app.test(.router) { client in
            let token = try await Self.signUpThenSignIn(client: client)

            // Set the LuminaVault default (managed) brain — the exact body the
            // iOS "Use LuminaVault Default" button sends. This is the request
            // that previously 500'd.
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: Self.auth(token),
                body: ByteBuffer(string: """
                {"mode":"managed","primaryProvider":"openRouter","primaryModel":"qwen/qwen-2.5-72b-instruct","fallbackChain":[]}
                """)
            ) { resp in
                #expect(resp.status == .ok)
                let prefs = try Self.decodePrefs(resp.body)
                #expect(prefs.mode == .managed)
                #expect(prefs.primaryProvider == .openRouter)
                #expect(prefs.primaryModel == "qwen/qwen-2.5-72b-instruct")
                #expect(prefs.fallbackChain.isEmpty)
            }

            // The saved preference round-trips on GET.
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .get,
                headers: Self.auth(token)
            ) { resp in
                #expect(resp.status == .ok)
                let prefs = try Self.decodePrefs(resp.body)
                #expect(prefs.mode == .managed)
                #expect(prefs.primaryProvider == .openRouter)
            }

            // Chat — managed mode routes through the table to the gateway,
            // which the stub backs. Proves auth → prefs → routing → reply.
            try await client.execute(
                uri: "/v1/llm/chat",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: """
                {"messages":[{"role":"user","content":"Hello, who are you?"}]}
                """)
            ) { resp in
                #expect(resp.status == .ok)
                let chat = try Self.decodeChat(resp.body)
                #expect(chat.message.role == "assistant")
                #expect(chat.message.content == Self.stubReply)
            }
        }
    }

    @Test
    func `byok preference with a non-empty fallback chain persists and round-trips`() async throws {
        // Directly exercises the jsonb bind that was broken: a fallback chain
        // with one step must save (200) and read back with the step intact.
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.signUpThenSignIn(client: client)

            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: Self.auth(token),
                body: ByteBuffer(string: """
                {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-7","fallbackChain":[{"provider":"openai","model":"gpt-4o"}]}
                """)
            ) { resp in
                #expect(resp.status == .ok)
                let prefs = try Self.decodePrefs(resp.body)
                #expect(prefs.mode == .byok)
                #expect(prefs.primaryProvider == .anthropic)
                #expect(prefs.fallbackChain.count == 1)
                #expect(prefs.fallbackChain[0].provider == .openai)
                #expect(prefs.fallbackChain[0].model == "gpt-4o")
            }

            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .get,
                headers: Self.auth(token)
            ) { resp in
                #expect(resp.status == .ok)
                let prefs = try Self.decodePrefs(resp.body)
                #expect(prefs.fallbackChain.count == 1)
                #expect(prefs.fallbackChain[0].provider == .openai)
            }
        }
    }

    /// A Nous-served free model (`stepfun/step-3.7-flash:free`) is selected and
    /// chatted with. Nous isn't a `ProviderID` — it's the Nous Portal OAuth
    /// subscription powering the per-tenant Hermes container — so the user
    /// selects its models through managed (gateway) mode carrying an
    /// OpenRouter-style slug. The controller does no catalog validation, so the
    /// slug rides through as a free-form string.
    ///
    /// Stubbed, this proves the model-selection → routing → reply path for the
    /// slug; it can't distinguish nous from the managed default or prove the
    /// live free tier answers (both share the gateway hop the stub backs). The
    /// assertion that earns its keep: the `:free` suffix survives the
    /// preference round-trip intact and reaches the chat hop unmangled.
    @Test
    func `select nous stepfun free model, then chat gets a reply`() async throws {
        let reply = "Reply from stepfun/step-3.7-flash:free via Nous."
        let model = "stepfun/step-3.7-flash:free"
        let app = try await buildApplication(reader: dbTestReaderWithStubChat(replyContent: reply))
        try await app.test(.router) { client in
            let token = try await Self.signUpThenSignIn(client: client)

            // Select the Nous free model: managed (gateway) mode, OpenRouter-style
            // carrier slug. This is the request the model picker sends.
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: Self.auth(token),
                body: ByteBuffer(string: """
                {"mode":"managed","primaryProvider":"openRouter","primaryModel":"\(model)","fallbackChain":[]}
                """)
            ) { resp in
                #expect(resp.status == .ok)
                let prefs = try Self.decodePrefs(resp.body)
                #expect(prefs.mode == .managed)
                #expect(prefs.primaryProvider == .openRouter)
                // The `:free` suffix must survive intact — no slug mangling.
                #expect(prefs.primaryModel == model)
            }

            // Round-trips on GET with the suffix preserved.
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .get,
                headers: Self.auth(token)
            ) { resp in
                #expect(resp.status == .ok)
                let prefs = try Self.decodePrefs(resp.body)
                #expect(prefs.primaryModel == model)
            }

            // Chat routes through the gateway and returns the assistant reply.
            try await client.execute(
                uri: "/v1/llm/chat",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: """
                {"messages":[{"role":"user","content":"Hello from the stepfun e2e test."}]}
                """)
            ) { resp in
                #expect(resp.status == .ok)
                let chat = try Self.decodeChat(resp.body)
                #expect(chat.message.role == "assistant")
                #expect(chat.message.content == reply)
            }
        }
    }
}
