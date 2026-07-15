@testable import App
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct KnowledgeVaultScopeIntegrationTests {
    private static let password = "CorrectHorseBatteryStaple1!"

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"knowledge-\(suffix)@test.luminavault","username":"knowledge-\(suffix)","password":"\(password)"}
            """)
        ) { response in
            #expect(response.status == .ok || response.status == .created)
            return try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
    }

    private static func createTeamVault(
        client: some TestClientProtocol,
        token: String
    ) async throws -> VaultResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let team = try await client.execute(
            uri: "/v1/teams",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"name":"Knowledge Team \#(suffix)"}"#)
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(TeamResponse.self, from: Data(buffer: response.body))
        }
        return try await client.execute(
            uri: "/v1/teams/\(team.id)/vaults",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"name":"Shared Brain"}"#)
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(VaultResponse.self, from: Data(buffer: response.body))
        }
    }

    @Test
    func `knowledge graph reads selected shared vault partition`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            let vault = try await Self.createTeamVault(client: client, token: owner.accessToken)
            let nodeID = UUID()

            try await withTestFluent(label: "knowledge.shared-vault.seed") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                let memory = Memory(tenantID: vault.id, content: "Atlas supports Beacon.")
                try await memory.save(on: fluent.db())
                let memoryID = try memory.requireID()
                try await sql.raw("""
                INSERT INTO knowledge_extraction_jobs (id, tenant_id, memory_id, content_fingerprint)
                VALUES (\(bind: UUID()), \(bind: vault.id), \(bind: memoryID), \(bind: "shared-vault-fingerprint"))
                """).run()
                try await sql.raw("""
                INSERT INTO knowledge_nodes (id, tenant_id, kind, canonical_key, label, confidence)
                VALUES (\(bind: nodeID), \(bind: vault.id), 'claim', \(bind: "atlas-supports-beacon"), 'Atlas supports Beacon.', 1.0)
                """).run()
            }

            let graph = try await client.execute(
                uri: "/v1/knowledge/graph",
                method: .get,
                headers: [
                    .authorization: "Bearer \(owner.accessToken)",
                    VaultAccessService.vaultHeader: vault.id.uuidString,
                ]
            ) { response in
                #expect(response.status == .ok)
                return try testJSONDecoder().decode(KnowledgeGraphResponse.self, from: Data(buffer: response.body))
            }
            #expect(graph.nodes.map(\.id).contains(nodeID))

            try await client.execute(
                uri: "/v1/knowledge/graph",
                method: .get,
                headers: [.authorization: "Bearer \(owner.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let personalGraph = try testJSONDecoder().decode(KnowledgeGraphResponse.self, from: Data(buffer: response.body))
                #expect(personalGraph.nodes.map(\.id).contains(nodeID) == false)
            }
        }
    }
}
