@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-37 — end-to-end tests for the multi-turn chat surface.
/// Drives `app.test(.router)` so a real JWT walks through the full
/// middleware chain. The streaming endpoint's LLM hop is NOT exercised
/// here (would require a stub HermesLLMStreamService injection point);
/// these tests cover CRUD + validation + auth + the wire shape of the
/// stream response on error paths. Requires `docker compose up -d
/// postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase)
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
                #expect(list.conversations[0].title == "three")
                #expect(list.conversations[2].title == "one")
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
