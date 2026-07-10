@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct UsabilityEndpointsTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("ux-\(suffix)@test.luminavault", "ux-\(suffix)")
    }

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
    }

    private static func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username)
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body)).accessToken
        }
    }

    @Test
    func `chat inbox returns conversation summaries`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let created: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"Usability planning"}"#)
            ) { response in
                #expect(response.status == .ok)
                return try testJSONDecoder().decode(ConversationDTO.self, from: Data(buffer: response.body))
            }

            try await client.execute(
                uri: "/v1/chat/inbox",
                method: .get,
                headers: Self.auth(token)
            ) { response in
                #expect(response.status == .ok)
                let inbox = try testJSONDecoder().decode(ChatInboxResponse.self, from: Data(buffer: response.body))
                let item = try #require(inbox.items.first)
                #expect(item.id == created.id)
                #expect(item.title == "Usability planning")
                #expect(item.messageCount == 0)
                #expect(item.sourceLabel == "Lumina")
            }
        }
    }

    @Test
    func `chat preferences default and persist`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            try await client.execute(
                uri: "/v1/me/chat-preferences",
                method: .get,
                headers: Self.auth(token)
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(ChatPreferencesGetResponse.self, from: Data(buffer: response.body))
                #expect(body.preferences.autoExpandThinking == true)
                #expect(body.preferences.sendOnReturn == false)
            }

            try await client.execute(
                uri: "/v1/me/chat-preferences",
                method: .put,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"preferences":{"autoExpandThinking":false,"sendOnReturn":true}}"#)
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(ChatPreferencesGetResponse.self, from: Data(buffer: response.body))
                #expect(body.preferences.autoExpandThinking == false)
                #expect(body.preferences.sendOnReturn == true)
            }
        }
    }

    @Test
    func `connections summary test-all and events are wired`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            try await client.execute(
                uri: "/v1/me/connections",
                method: .get,
                headers: Self.auth(token)
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(ConnectionsSummaryResponse.self, from: Data(buffer: response.body))
                #expect(body.connections.contains { $0.id == "server:api" && $0.health == .connected })
                #expect(body.connections.contains { $0.id == "provider:openRouter" && $0.health == .needsSetup })
                #expect(body.connections.contains { $0.id == "calendar:google" && $0.health == .needsSetup })
            }

            let testAll: ConnectionsTestAllResponse = try await client.execute(
                uri: "/v1/me/connections/test-all",
                method: .post,
                headers: Self.auth(token)
            ) { response in
                #expect(response.status == .ok)
                return try testJSONDecoder().decode(ConnectionsTestAllResponse.self, from: Data(buffer: response.body))
            }
            #expect(testAll.results.contains { $0.id == "server:api" && $0.ok == true })
            #expect(testAll.results.contains { $0.id == "provider:openRouter" && $0.health == .needsSetup })

            try await client.execute(
                uri: "/v1/me/connections/events?limit=100",
                method: .get,
                headers: Self.auth(token)
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(ConnectionDiagnosticEventsResponse.self, from: Data(buffer: response.body))
                #expect(body.events.isEmpty == false)
                #expect(body.events.contains { $0.connectionID == "server:api" })
            }
        }
    }

    @Test
    func `usability endpoints require auth`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            for uri in ["/v1/chat/inbox", "/v1/me/chat-preferences", "/v1/me/connections", "/v1/me/connections/events"] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            try await client.execute(uri: "/v1/me/connections/test-all", method: .post) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
