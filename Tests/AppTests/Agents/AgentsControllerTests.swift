@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// `/v1/agents` against Postgres. The central agent's sessions are the
/// caller's own conversations — never another user's.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AgentsControllerTests {
    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"agents-\(suffix)@test.luminavault","username":"agents-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken }
    }

    private static func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func createConversation(_ title: String, token: String, client: some TestClientProtocol) async throws -> UUID {
        try await client.execute(
            uri: "/v1/conversations",
            method: .post,
            headers: auth(token),
            body: ByteBuffer(string: #"{"title":"\#(title)"}"#)
        ) { try testJSONDecoder().decode(ConversationDTO.self, from: Data($0.body.readableBytesView)).id }
    }

    @Test
    func `a user sees only their own central sessions and logs`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.register(client: client)
            let bob = try await Self.register(client: client)
            let alicesID = try await Self.createConversation("Alice plans", token: alice, client: client)
            _ = try await Self.createConversation("Bob plans", token: bob, client: client)

            // Instances: the central agent is always there; no BYO configured.
            try await client.execute(uri: "/v1/agents/instances", method: .get, headers: Self.auth(alice)) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(AgentInstancesResponse.self, from: Data(response.body.readableBytesView))
                #expect(body.instances.map(\.id) == ["central"])
            }

            try await client.execute(uri: "/v1/agents/sessions", method: .get, headers: Self.auth(alice)) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(AgentSessionsResponse.self, from: Data(response.body.readableBytesView))
                #expect(body.sessions.map(\.title) == ["Alice plans"])
                #expect(body.sessions.first?.source == "app")
                #expect(body.sessions.first?.isActive == true)
                #expect(body.errors.isEmpty)
            }

            // A profile filter can only match a Hermes profile, never central.
            try await client.execute(uri: "/v1/agents/sessions?profile=default", method: .get, headers: Self.auth(alice)) { response in
                let body = try testJSONDecoder().decode(AgentSessionsResponse.self, from: Data(response.body.readableBytesView))
                #expect(body.sessions.isEmpty)
            }

            let log = "/v1/agents/instances/central/sessions/\(alicesID.uuidString)/messages"
            try await client.execute(uri: log, method: .get, headers: Self.auth(alice)) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(AgentSessionMessagesResponse.self, from: Data(response.body.readableBytesView))
                #expect(body.sessionID == alicesID.uuidString)
            }
            // Bob cannot read Alice's log by guessing its id.
            try await client.execute(uri: log, method: .get, headers: Self.auth(bob)) { response in
                #expect(response.status == .notFound)
            }

            // No BYO gateway configured → the byo instance does not exist.
            try await client.execute(
                uri: "/v1/agents/instances/byo/sessions/s1/messages", method: .get, headers: Self.auth(alice)
            ) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/v1/agents/sessions?instance=nope", method: .get, headers: Self.auth(alice)) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/v1/agents/sessions", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
