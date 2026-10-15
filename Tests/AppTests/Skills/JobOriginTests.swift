@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// A job proposed in a chat links back to that chat, both in the create
/// response and in the skills list, and only to a chat of the caller's own.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct JobOriginTests {
    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"origin-\#(suffix)@test.luminavault","username":"origin\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken }
    }

    private static func headers(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func conversation(client: some TestClientProtocol, token: String) async throws -> UUID {
        try await client.execute(
            uri: "/v1/conversations",
            method: .post,
            headers: headers(token),
            body: ByteBuffer(string: #"{"title":"Planning"}"#)
        ) { try testJSONDecoder().decode(ConversationDTO.self, from: Data($0.body.readableBytesView)).id }
    }

    private static func createJob(
        client: some TestClientProtocol,
        token: String,
        title: String,
        conversationID: UUID
    ) async throws -> (HTTPResponse.Status, SkillDTO?) {
        let body = #"{"title":"\#(title)","cron":"0 9 * * 1","spec":"Summarize the week","conversationId":"\#(conversationID)"}"#
        return try await client.execute(
            uri: "/v1/jobs",
            method: .post,
            headers: headers(token),
            body: ByteBuffer(string: body)
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(SkillDTO.self, from: Data(response.body.readableBytesView)))
        }
    }

    @Test
    func `a job proposed in a chat links back to it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let chat = try await Self.conversation(client: client, token: token)
            let title = "Weekly review \(UUID().uuidString.prefix(6))"

            let (status, job) = try await Self.createJob(client: client, token: token, title: title, conversationID: chat)
            #expect(status == .ok)
            #expect(job?.origin == JobOriginDTO(kind: .conversation, id: chat))

            let listed: SkillListResponse = try await client.execute(
                uri: "/v1/skills",
                method: .get,
                headers: Self.headers(token)
            ) { try testJSONDecoder().decode(SkillListResponse.self, from: Data($0.body.readableBytesView)) }
            let row = try #require(listed.skills.first { $0.name == job?.name })
            #expect(row.origin == JobOriginDTO(kind: .conversation, id: chat))
        }
    }

    @Test
    func `another account's chat is refused`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            let chat = try await Self.conversation(client: client, token: owner)
            let other = try await Self.register(client: client)
            let (status, _) = try await Self.createJob(client: client, token: other, title: "Steal", conversationID: chat)
            #expect(status == .badRequest)
        }
    }
}
