@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// `/v1/agents/rooms` over HTTP: seating, ownership, stop.
/// Agent turns themselves are covered by `AgentRoomOrchestratorTests`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AgentRoomsControllerTests {
    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"rooms-\(suffix)@test.luminavault","username":"rooms-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(uri: "/v1/auth/register", method: .post, headers: [.contentType: "application/json"], body: body) {
            try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken
        }
    }

    private static func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func decode<T: Decodable>(_: T.Type, _ response: TestResponse) throws -> T {
        try testJSONDecoder().decode(T.self, from: Data(response.body.readableBytesView))
    }

    @Test
    func `a room seats only the caller's own personas and only the caller can open it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.register(client: client)
            let bob = try await Self.register(client: client)
            for (slug, label) in [("research", "Research"), ("ops", "Ops")] {
                try await client.execute(
                    uri: "/v1/profiles", method: .post, headers: Self.auth(alice),
                    body: ByteBuffer(string: #"{"slug":"\#(slug)","label":"\#(label)"}"#),
                ) { #expect($0.status == .ok || $0.status == .created) }
            }

            try await client.execute(uri: "/v1/agents/room-candidates", method: .get, headers: Self.auth(alice)) { response in
                let body = try Self.decode(AgentRoomCandidatesResponse.self, response)
                #expect(Set(body.candidates.compactMap(\.profile)).isSuperset(of: ["research", "ops"]))
                #expect(!body.candidates.contains { $0.instanceID == "byo" })
            }

            let create = ByteBuffer(string: """
            {"title":"Trip planning","members":[
              {"instanceID":"central","profile":"research","respondMode":"every_human_message"},
              {"instanceID":"central","profile":"ops"}]}
            """)
            let room = try await client.execute(uri: "/v1/agents/rooms", method: .post, headers: Self.auth(alice), body: create) { response in
                #expect(response.status == .ok)
                return try Self.decode(AgentRoomDetailResponse.self, response).room
            }
            #expect(room.members.map(\.handle) == ["research", "ops"])
            #expect(room.members.map(\.respondMode) == [.everyHumanMessage, .mention])
            #expect(room.spentTokens == 0)

            // Bob cannot seat Alice's persona, open, post to, stop or delete her room.
            try await client.execute(
                uri: "/v1/agents/rooms", method: .post, headers: Self.auth(bob),
                body: ByteBuffer(string: #"{"title":"x","members":[{"instanceID":"central","profile":"research"}]}"#),
            ) { #expect($0.status == .badRequest) }
            let path = "/v1/agents/rooms/\(room.id.uuidString)"
            try await client.execute(uri: path, method: .get, headers: Self.auth(bob)) { #expect($0.status == .notFound) }
            try await client.execute(
                uri: path + "/messages", method: .post, headers: Self.auth(bob), body: ByteBuffer(string: #"{"body":"hi"}"#),
            ) { #expect($0.status == .notFound) }
            try await client.execute(uri: path + "/stop", method: .post, headers: Self.auth(bob)) { #expect($0.status == .notFound) }
            try await client.execute(uri: path, method: .delete, headers: Self.auth(bob)) { #expect($0.status == .notFound) }

            // Alice sees it, can stop it, and an empty post is refused before any agent runs.
            try await client.execute(uri: "/v1/agents/rooms", method: .get, headers: Self.auth(alice)) { response in
                let rooms = try Self.decode(AgentRoomsResponse.self, response).rooms
                #expect(rooms.map(\.id) == [room.id])
            }
            try await client.execute(uri: path + "/stop", method: .post, headers: Self.auth(alice)) { #expect($0.status == .accepted) }
            try await client.execute(
                uri: path + "/messages", method: .post, headers: Self.auth(alice), body: ByteBuffer(string: #"{"body":"   "}"#),
            ) { #expect($0.status == .badRequest) }
            try await client.execute(uri: path, method: .delete, headers: Self.auth(alice)) { #expect($0.status == .noContent) }
            try await client.execute(uri: path, method: .get, headers: Self.auth(alice)) { #expect($0.status == .notFound) }
        }
    }

    @Test
    func `invalid rooms are refused`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.register(client: client)
            for body in [
                #"{"title":"","members":[{"instanceID":"central","profile":"default"}]}"#,
                #"{"title":"No one","members":[]}"#,
                #"{"title":"Ghost","members":[{"instanceID":"byo"}]}"#,
            ] {
                try await client.execute(
                    uri: "/v1/agents/rooms", method: .post, headers: Self.auth(alice), body: ByteBuffer(string: body),
                ) { #expect($0.status == .badRequest, "\(body)") }
            }
        }
    }
}
