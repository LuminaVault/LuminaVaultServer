@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-37 — end-to-end tests for the multi-turn chat surface.
/// Drives `app.test(.router)` so a real JWT walks through the full
/// middleware chain. CRUD, validation, auth, and — since HER-330 — the
/// streaming path actually running, via `dbTestReaderWithStubChat`.
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct ConversationE2ETests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("conv-e2e-\(suffix)@test.luminavault", "conv-e2e-\(suffix)")
    }

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
    }

    private static func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func decodeConversation(_ buf: ByteBuffer) throws -> ConversationDTO {
        try testJSONDecoder().decode(ConversationDTO.self, from: Data(buffer: buf))
    }

    private static func decodeConversationList(_ buf: ByteBuffer) throws -> ConversationListResponse {
        try testJSONDecoder().decode(ConversationListResponse.self, from: Data(buffer: buf))
    }

    private static func decodeConversationDetail(_ buf: ByteBuffer) throws -> ConversationDetailResponse {
        try testJSONDecoder().decode(ConversationDetailResponse.self, from: Data(buffer: buf))
    }

    /// Register a fresh user and return their access token.
    private static func registerUser(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username)
        ) { resp in
            #expect(resp.status == .ok)
            return try decodeAuth(resp.body).accessToken
        }
    }

    // MARK: - CRUD

    @Test
    func `POST conversations creates a row owned by the caller`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"Sleep patterns"}"#)
            ) { resp in
                #expect(resp.status == .ok)
                let convo = try Self.decodeConversation(resp.body)
                #expect(convo.title == "Sleep patterns")
            }
        }
    }

    @Test
    func `POST conversations falls back to a default title on blank input`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"   "}"#)
            ) { resp in
                #expect(resp.status == .ok)
                let convo = try Self.decodeConversation(resp.body)
                #expect(convo.title == "New conversation")
            }
        }
    }

    @Test
    func `GET conversations lists newest first`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            for title in ["one", "two", "three"] {
                try await client.execute(
                    uri: "/v1/conversations",
                    method: .post,
                    headers: Self.auth(token),
                    body: ByteBuffer(string: #"{"title":"\#(title)"}"#)
                ) { resp in #expect(resp.status == .ok) }
            }
            try await client.execute(
                uri: "/v1/conversations",
                method: .get,
                headers: Self.auth(token)
            ) { resp in
                #expect(resp.status == .ok)
                let list = try Self.decodeConversationList(resp.body)
                #expect(list.conversations.count == 3)
                // `#expect` records and continues, so subscripting a short
                // list here traps and aborts the whole integration run.
                #expect(list.conversations.first?.title == "three")
                #expect(list.conversations.dropFirst(2).first?.title == "one")
            }
        }
    }

    @Test
    func `GET conversation by id returns DTO and empty transcript`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let created: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"detail"}"#)
            ) { try Self.decodeConversation($0.body) }
            try await client.execute(
                uri: "/v1/conversations/\(created.id)",
                method: .get,
                headers: Self.auth(token)
            ) { resp in
                #expect(resp.status == .ok)
                let detail = try Self.decodeConversationDetail(resp.body)
                #expect(detail.conversation.id == created.id)
                #expect(detail.messages.isEmpty)
            }
        }
    }

    @Test
    func `DELETE conversation removes it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let created: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"trash"}"#)
            ) { try Self.decodeConversation($0.body) }
            try await client.execute(
                uri: "/v1/conversations/\(created.id)",
                method: .delete,
                headers: Self.auth(token)
            ) { resp in #expect(resp.status == .noContent) }
            try await client.execute(
                uri: "/v1/conversations/\(created.id)",
                method: .get,
                headers: Self.auth(token)
            ) { resp in #expect(resp.status == .notFound) }
        }
    }

    @Test
    func `cross-tenant conversation access returns 404`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tokenA = try await Self.registerUser(client: client)
            let tokenB = try await Self.registerUser(client: client)
            let aConvo: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(tokenA),
                body: ByteBuffer(string: #"{"title":"private"}"#)
            ) { try Self.decodeConversation($0.body) }
            try await client.execute(
                uri: "/v1/conversations/\(aConvo.id)",
                method: .get,
                headers: Self.auth(tokenB)
            ) { resp in #expect(resp.status == .notFound) }
        }
    }

    @Test
    func `unauthenticated request to conversations returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/conversations", method: .get) { resp in
                #expect(resp.status == .unauthorized)
            }
        }
    }

    // MARK: - Streaming validation (no LLM hop)

    @Test
    func `POST messages-stream with empty content returns 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let convo: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"x"}"#)
            ) { try Self.decodeConversation($0.body) }
            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"   "}"#)
            ) { resp in #expect(resp.status == .badRequest) }
        }
    }

    /// HER-330 — drives a stream that actually reaches the routing block.
    ///
    /// The two tests below stop at 400/404, which return before
    /// `streamReply` ever starts its `Task` — so nothing exercised the part
    /// that mattered. Binding ten `@TaskLocal`s there segfaulted the whole
    /// process on every real chat message, in production, for as long as
    /// anyone had been sending them, and CI stayed green throughout.
    ///
    /// This asserts little about the reply, deliberately: the stub provider
    /// has no native streaming, so the body may carry an error event rather
    /// than tokens. What it proves is that the routing block runs and the
    /// process survives it. A segfault here takes the test binary with it,
    /// which is exactly the signal that was missing.
    @Test
    func `POST messages-stream runs the routing block without crashing`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let convo: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"stream"}"#)
            ) { try Self.decodeConversation($0.body) }

            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"hello"}"#)
            ) { resp in
                // `streamReply` answers with the SSE response before the
                // upstream hop, so the status is 200 whatever the provider
                // does next.
                #expect(resp.status == .ok)
            }
        }
    }

    /// A stream that fails for a reason the user can act on must say what it
    /// is. The conversation stream answers 200 before the upstream hop, so a
    /// failure arrives as an SSE `error` event rather than a status, and the
    /// controller used to replace everything except a provider error with the
    /// text "upstream failure". Here a BYOK user with no key is sent to the
    /// free lane, which has no providers in tests, so the stream fails with a
    /// routing error that carries its own user message — and the user saw
    /// "upstream failure" instead of it.
    @Test
    func `a routing failure mid-stream reaches the user as its own message`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: Self.auth(token),
                body: ByteBuffer(string: """
                {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-7","fallbackChain":[]}
                """)
            ) { #expect($0.status == .ok) }

            let convo: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"stream"}"#)
            ) { try Self.decodeConversation($0.body) }

            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"hello"}"#)
            ) { resp in
                #expect(resp.status == .ok)
                let errors = Self.sseErrorMessages(in: String(buffer: resp.body))
                let message = try #require(errors.first, "the stream carried no error event")
                #expect(message != "upstream failure")
                #expect(message.isEmpty == false)
                // The ways out travel with it, so a client can offer them as
                // buttons: this trial user can add a key or use managed.
                let frame = try #require(Self.sseErrorFrames(in: String(buffer: resp.body)).first)
                #expect(frame["code"] as? String == "free_lane_unavailable")
                #expect(frame["cta"] as? [String] == ["add_key", "switch_to_managed"])
            }
        }
    }

    /// `/v1/query/stream` used the raw Hermes stream service, with no router
    /// at all, so a free-tier user's query skipped the free lane and its
    /// allowance and was served on the managed gateway's paid key — the same
    /// leak the conversation stream had, by a different door. A lapsed user is
    /// forced onto the lane; with no lane providers loaded in tests the lane
    /// refuses the turn, and that refusal is what must reach the user. Before
    /// the fix the query went to the gateway instead, which is unreachable in
    /// tests, and the user saw "upstream failure".
    @Test
    func `a free-tier query stream goes through the free lane, not the gateway`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let (email, username) = Self.randomUser()
            let auth = try await client.execute(
                uri: "/v1/auth/register",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.registerBody(email: email, username: username)
            ) { try Self.decodeAuth($0.body) }

            try await withTestFluent(label: "lv.test.query-stream.lapsed") { fluent in
                let user = try #require(try await User.find(auth.userId, on: fluent.db()))
                user.tier = "lapsed"
                try await user.save(on: fluent.db())
            }

            try await client.execute(
                uri: "/v1/query/stream",
                method: .post,
                headers: Self.auth(auth.accessToken),
                body: ByteBuffer(string: #"{"query":"what did I save?"}"#)
            ) { resp in
                #expect(resp.status == .ok)
                let errors = Self.sseErrorMessages(in: String(buffer: resp.body))
                let message = try #require(errors.first, "the stream carried no error event")
                #expect(message == FreeLaneUnavailableError(actions: []).userMessage)
                let frame = try #require(Self.sseErrorFrames(in: String(buffer: resp.body)).first)
                #expect(frame["code"] as? String == "free_lane_unavailable")
                #expect(frame["cta"] as? [String] == ["upgrade", "add_key"])
            }
        }
    }

    /// The `error` payloads of an SSE body, in order.
    private static func sseErrorMessages(in body: String) -> [String] {
        sseErrorFrames(in: body).compactMap { $0["payload"] as? String }
    }

    /// The whole `error` frames of an SSE body, in order.
    private static func sseErrorFrames(in body: String) -> [[String: Any]] {
        body.components(separatedBy: "\n")
            .filter { $0.hasPrefix("data:") }
            .compactMap { line -> [String: Any]? in
                let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard let data = json.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["type"] as? String == "error"
                else { return nil }
                return event
            }
    }

    @Test
    func `POST messages-stream on unknown id returns 404`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let bogus = UUID()
            try await client.execute(
                uri: "/v1/conversations/\(bogus)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"hi"}"#)
            ) { resp in #expect(resp.status == .notFound) }
        }
    }
}
