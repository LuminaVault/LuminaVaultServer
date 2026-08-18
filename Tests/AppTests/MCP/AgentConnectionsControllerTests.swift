@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AgentConnectionsControllerTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("mcp-\(suffix)@test.luminavault", "mcp-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let body = ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken }
    }

    @Test
    func `issue list revoke and never echo the token later`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let jwt = try await Self.register(client: client)

            let issued: AgentConnectionIssuedResponse = try await client.execute(
                uri: "/v1/me/agent-connections",
                method: .post,
                headers: [
                    .authorization: "Bearer \(jwt)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"name":"laptop","clientKind":"claude_code"}"#)
            ) { response in
                #expect(response.status == .ok)
                return try testJSONDecoder().decode(
                    AgentConnectionIssuedResponse.self,
                    from: Data(response.body.readableBytesView)
                )
            }
            #expect(issued.token.hasPrefix("lv_"))
            #expect(issued.connection.tokenPrefix == String(issued.token.prefix(11)))
            #expect(issued.setup.url == "https://api.example.com/v1/mcp")
            #expect(issued.setup.config.contains(issued.token))

            try await client.execute(
                uri: "/v1/me/agent-connections",
                method: .get,
                headers: [.authorization: "Bearer \(jwt)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try testJSONDecoder().decode(
                    AgentConnectionsListResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(list.connections.count == 1)
                #expect(list.connections[0].id == issued.connection.id)
                let encoded = String(data: Data(response.body.readableBytesView), encoding: .utf8) ?? ""
                #expect(!encoded.contains(issued.token))
            }

            try await client.execute(
                uri: "/v1/me/agent-connections/\(issued.connection.id.uuidString)",
                method: .delete,
                headers: [.authorization: "Bearer \(jwt)"]
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/v1/me/agent-connections",
                method: .get,
                headers: [.authorization: "Bearer \(jwt)"]
            ) { response in
                let list = try testJSONDecoder().decode(
                    AgentConnectionsListResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(list.connections.isEmpty)
            }
        }
    }

    @Test
    func `preview uses the placeholder and does not issue a key`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let jwt = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/agent-connections/preview?clientKind=codex",
                method: .get,
                headers: [.authorization: "Bearer \(jwt)"]
            ) { response in
                #expect(response.status == .ok)
                let setup = try testJSONDecoder().decode(
                    AgentConnectionSetupDTO.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(setup.token == AgentConnectionService.placeholderToken)
                #expect(setup.kind == .codex)
            }
            try await client.execute(
                uri: "/v1/me/agent-connections",
                method: .get,
                headers: [.authorization: "Bearer \(jwt)"]
            ) { response in
                let list = try testJSONDecoder().decode(
                    AgentConnectionsListResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(list.connections.isEmpty)
            }
        }
    }

    @Test
    func `agent token authenticates MCP; revoked token does not`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let jwt = try await Self.register(client: client)
            let issued: AgentConnectionIssuedResponse = try await client.execute(
                uri: "/v1/me/agent-connections",
                method: .post,
                headers: [
                    .authorization: "Bearer \(jwt)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"name":"codex","clientKind":"codex"}"#)
            ) { response in
                try testJSONDecoder().decode(
                    AgentConnectionIssuedResponse.self,
                    from: Data(response.body.readableBytesView)
                )
            }

            let listTools = ByteBuffer(string: """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """)
            try await client.execute(
                uri: "/v1/mcp",
                method: .post,
                headers: [
                    .authorization: "Bearer \(issued.token)",
                    .contentType: "application/json",
                ],
                body: listTools
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"search\""))
                #expect(body.contains("\"status\""))
            }

            try await client.execute(
                uri: "/v1/mcp",
                method: .post,
                headers: [.contentType: "application/json"],
                body: listTools
            ) { response in
                #expect(response.status == .unauthorized)
            }

            try await client.execute(
                uri: "/v1/mcp",
                method: .post,
                headers: [
                    .authorization: "Bearer \(issued.token)",
                    .contentType: "application/json",
                    .origin: "https://evil.example",
                ],
                body: listTools
            ) { response in
                #expect(response.status == .forbidden)
            }

            try await client.execute(
                uri: "/v1/me/agent-connections/\(issued.connection.id.uuidString)",
                method: .delete,
                headers: [.authorization: "Bearer \(jwt)"]
            ) { _ in }

            try await client.execute(
                uri: "/v1/mcp",
                method: .post,
                headers: [
                    .authorization: "Bearer \(issued.token)",
                    .contentType: "application/json",
                ],
                body: listTools
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `blank name is rejected`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let jwt = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/agent-connections",
                method: .post,
                headers: [
                    .authorization: "Bearer \(jwt)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"name":"   ","clientKind":"other"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
