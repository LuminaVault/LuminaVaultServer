@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// A memory can be moved to another Space, or out of every Space, and the
/// list can be narrowed to one Space. A memory compiled from a note goes
/// wherever its note goes, so moving it moves the note.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemorySpaceMoveTests {
    private struct Account {
        let userID: UUID
        let token: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"move-\#(suffix)@test.luminavault","username":"move\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func upsert(client: some TestClientProtocol, token: String, content: String) async throws -> UUID {
        try await client.execute(
            uri: "/v1/memory/upsert",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"content":"\#(content)"}"#)
        ) { try testJSONDecoder().decode(MemoryUpsertResponse.self, from: Data($0.body.readableBytesView)).memoryId }
    }

    private static func patch(
        client: some TestClientProtocol,
        token: String,
        id: UUID,
        body: String
    ) async throws -> (HTTPResponse.Status, MemoryDTO?) {
        try await client.execute(
            uri: "/v1/memory/\(id)",
            method: .patch,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: body)
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(MemoryDTO.self, from: Data(response.body.readableBytesView)))
        }
    }

    private static func listIDs(client: some TestClientProtocol, token: String, space: String) async throws -> [UUID] {
        try await client.execute(
            uri: "/v1/memory?space=\(space)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(MemoryListResponse.self, from: Data(response.body.readableBytesView)).memories.map(\.id)
        }
    }

    @Test
    func `a memory moves into a Space, shows up there, and can be unfiled`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            try await withTestFluent(label: "test.memory.move") { fluent in
                let space = Space(tenantID: account.userID, name: "Work", slug: "work")
                try await space.save(on: fluent.db())
                let spaceID = try space.requireID()
                let id = try await Self.upsert(client: client, token: account.token, content: "Standup is at nine.")

                let (status, moved) = try await Self.patch(
                    client: client, token: account.token, id: id, body: #"{"spaceId":"\#(spaceID)"}"#
                )
                #expect(status == .ok)
                #expect(moved?.spaceId == spaceID)
                #expect(moved?.content == "Standup is at nine.")
                #expect(try await Self.listIDs(client: client, token: account.token, space: "work").contains(id))
                #expect(try await !Self.listIDs(client: client, token: account.token, space: "inbox").contains(id))

                let (_, unfiled) = try await Self.patch(
                    client: client, token: account.token, id: id, body: #"{"spaceId":null}"#
                )
                #expect(unfiled?.spaceId == nil)
                #expect(try await Self.listIDs(client: client, token: account.token, space: "inbox").contains(id))

                let provenance: MemoryProvenanceResponse = try await client.execute(
                    uri: "/v1/memory/\(id)/provenance",
                    method: .get,
                    headers: [.authorization: "Bearer \(account.token)"]
                ) { try testJSONDecoder().decode(MemoryProvenanceResponse.self, from: Data($0.body.readableBytesView)) }
                #expect(provenance.contributions.filter { $0.operation == .update && $0.actor == .user }.count == 2)
            }
        }
    }

    @Test
    func `moving a note-backed memory moves its note`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            try await withTestFluent(label: "test.memory.move.note") { fluent in
                let space = Space(tenantID: account.userID, name: "Work", slug: "work")
                try await space.save(on: fluent.db())
                let spaceID = try space.requireID()
                let file = VaultFile(
                    tenantID: account.userID,
                    path: "inbox/plan.md",
                    contentType: "text/markdown",
                    sizeBytes: 0,
                    sha256: String(repeating: "0", count: 64)
                )
                try await file.save(on: fluent.db())
                let memory = try await MemoryRepository(fluent: fluent).create(
                    tenantID: account.userID,
                    content: "Plan the launch.",
                    embedding: DeterministicEmbeddingService().embed("Plan the launch.", tenantID: account.userID),
                    sourceVaultFileID: file.requireID()
                )

                let (status, moved) = try await Self.patch(
                    client: client, token: account.token, id: memory.requireID(), body: #"{"spaceId":"\#(spaceID)"}"#
                )
                #expect(status == .ok)
                #expect(moved?.spaceId == spaceID)
                let note = try #require(try await VaultFile.query(on: fluent.db(), tenantID: account.userID)
                    .filter(\.$id == file.requireID())
                    .first())
                #expect(note.path == "work/plan.md")
                #expect(note.spaceID == spaceID)
            }
        }
    }

    @Test
    func `another account's Space and an unknown slug are refused`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            let other = try await Self.register(client: client)
            try await withTestFluent(label: "test.memory.move.foreign") { fluent in
                let foreign = Space(tenantID: other.userID, name: "Theirs", slug: "theirs")
                try await foreign.save(on: fluent.db())
                let id = try await Self.upsert(client: client, token: owner.token, content: "Mine.")
                let (status, _) = try await Self.patch(
                    client: client, token: owner.token, id: id, body: #"{"spaceId":"\#(foreign.requireID())"}"#
                )
                #expect(status == .badRequest)

                try await client.execute(
                    uri: "/v1/memory?space=nope",
                    method: .get,
                    headers: [.authorization: "Bearer \(owner.token)"]
                ) { #expect($0.status == .notFound) }
            }
        }
    }
}
