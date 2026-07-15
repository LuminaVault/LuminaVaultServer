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
struct MultimodalIngestionAPIIntegrationTests {
    private static let password = "CorrectHorseBatteryStaple1!"

    private static func register(client: some TestClientProtocol, prefix: String) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(prefix)-\(suffix)@test.luminavault","username":"\(prefix)-\(suffix)","password":"\(password)"}
            """)
        ) { response in
            #expect(response.status == .ok || response.status == .created)
            return try decode(AuthResponse.self, response.body)
        }
    }

    private static func createFileBatch(
        client: some TestClientProtocol,
        token: String,
        bytes: Data,
        vaultID: UUID? = nil
    ) async throws -> IngestionBatchDTO {
        let request = IngestionCreateRequest(items: [
            IngestionCreateItemRequest(
                kind: .file,
                fileName: "integration.txt",
                contentType: "text/plain",
                sizeBytes: Int64(bytes.count)
            ),
        ])
        var headers: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]
        if let vaultID {
            headers[VaultAccessService.vaultHeader] = vaultID.uuidString
        }
        return try await client.execute(
            uri: "/v1/ingestions",
            method: .post,
            headers: headers,
            body: ByteBuffer(data: JSONEncoder().encode(request))
        ) { response in
            #expect(response.status == .ok)
            return try decode(IngestionBatchDTO.self, response.body)
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
            body: ByteBuffer(string: #"{"name":"Ingestion Team \#(suffix)"}"#)
        ) { response in
            #expect(response.status == .ok)
            return try decode(TeamResponse.self, response.body)
        }
        return try await client.execute(
            uri: "/v1/teams/\(team.id)/vaults",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"name":"Shared Capture"}"#)
        ) { response in
            #expect(response.status == .ok)
            return try decode(VaultResponse.self, response.body)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ body: ByteBuffer) throws -> T {
        try testJSONDecoder().decode(type, from: Data(buffer: body))
    }

    @Test
    func `upload completes into the vault and cancellation is idempotent`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client, prefix: "ing-upload")
            let bytes = Data("durable ingestion upload".utf8)
            let batch = try await Self.createFileBatch(client: client, token: auth.accessToken, bytes: bytes)
            let item = try #require(batch.items.first)

            try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)/chunks/0",
                method: .put,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/octet-stream"],
                body: ByteBuffer(data: bytes)
            ) { response in
                #expect(response.status == .noContent)
            }

            let completed = try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)/complete",
                method: .post,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                return try Self.decode(IngestionBatchDTO.self, response.body)
            }
            let stored = try #require(completed.items.first)
            #expect(stored.state == .queued)
            #expect(stored.uploadedBytes == Int64(bytes.count))
            #expect(stored.vaultFileID != nil)
            #expect(stored.contentSHA256 != nil)

            let cancelled = try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { try Self.decode(IngestionBatchDTO.self, $0.body) }
            #expect(cancelled.items.first?.state == .cancelled)

            let cancelledAgain = try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { try Self.decode(IngestionBatchDTO.self, $0.body) }
            #expect(cancelledAgain.items.first?.state == .cancelled)
        }
    }

    @Test
    func `ingestion batches and mutations are tenant isolated`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client, prefix: "ing-owner")
            let intruder = try await Self.register(client: client, prefix: "ing-intruder")
            let batch = try await Self.createFileBatch(client: client, token: owner.accessToken, bytes: Data("private".utf8))
            let item = try #require(batch.items.first)

            try await client.execute(
                uri: "/v1/ingestions/\(batch.id)",
                method: .get,
                headers: [.authorization: "Bearer \(intruder.accessToken)"]
            ) { #expect($0.status == .notFound) }
            try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)",
                method: .delete,
                headers: [.authorization: "Bearer \(intruder.accessToken)"]
            ) { #expect($0.status == .notFound) }

            let ownerDetail = try await client.execute(
                uri: "/v1/ingestions/\(batch.id)",
                method: .get,
                headers: [.authorization: "Bearer \(owner.accessToken)"]
            ) { try Self.decode(IngestionBatchDTO.self, $0.body) }
            #expect(ownerDetail.items.first?.state == .awaitingUpload)
        }
    }

    @Test
    func `shared vault ingestion uses requested vault partition`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client, prefix: "ing-shared")
            let vault = try await Self.createTeamVault(client: client, token: owner.accessToken)
            let bytes = Data("team vault upload".utf8)
            let batch = try await Self.createFileBatch(
                client: client,
                token: owner.accessToken,
                bytes: bytes,
                vaultID: vault.id
            )
            let item = try #require(batch.items.first)
            let vaultHeaders: HTTPFields = [
                .authorization: "Bearer \(owner.accessToken)",
                VaultAccessService.vaultHeader: vault.id.uuidString,
            ]

            try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)/chunks/0",
                method: .put,
                headers: vaultHeaders,
                body: ByteBuffer(data: bytes)
            ) { response in
                #expect(response.status == .noContent)
            }
            let completed = try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(item.id)/complete",
                method: .post,
                headers: vaultHeaders
            ) { response in
                #expect(response.status == .ok)
                return try Self.decode(IngestionBatchDTO.self, response.body)
            }
            let completedItem = try #require(completed.items.first)
            let vaultFileID = try #require(completedItem.vaultFileID)

            try await withTestFluent(label: "ingestion.shared-vault.assert") { fluent in
                let storedBatch = try #require(try await IngestionBatch.find(batch.id, on: fluent.db()))
                #expect(storedBatch.tenantID == vault.id)
                let storedFile = try #require(try await VaultFile.find(vaultFileID, on: fluent.db()))
                #expect(storedFile.tenantID == vault.id)
            }

            try await client.execute(
                uri: "/v1/ingestions/\(batch.id)",
                method: .get,
                headers: [.authorization: "Bearer \(owner.accessToken)"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `failed item can retry and clears transient worker state`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client, prefix: "ing-retry")
            let batch = try await Self.createFileBatch(client: client, token: auth.accessToken, bytes: Data("retry".utf8))
            let itemID = try #require(batch.items.first?.id)

            try await withTestFluent(label: "ingestion.retry.seed") { fluent in
                let item = try #require(try await IngestionItem.find(itemID, on: fluent.db()))
                item.state = IngestionItemStateDTO.failed.rawValue
                item.errorMessage = "upstream unavailable"
                item.nextAttemptAt = Date().addingTimeInterval(300)
                item.leaseExpiresAt = Date().addingTimeInterval(300)
                item.sourceTokenHash = String(repeating: "f", count: 64)
                item.sourceTokenExpiresAt = Date().addingTimeInterval(300)
                item.terminalNotifiedAt = Date()
                try await item.save(on: fluent.db())
            }

            let retried = try await client.execute(
                uri: "/v1/ingestions/\(batch.id)/items/\(itemID)/retry",
                method: .post,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                return try Self.decode(IngestionBatchDTO.self, response.body)
            }
            let item = try #require(retried.items.first)
            #expect(item.state == .queued)
            #expect(item.error == nil)

            try await withTestFluent(label: "ingestion.retry.assert") { fluent in
                let row = try #require(try await IngestionItem.find(itemID, on: fluent.db()))
                #expect(row.nextAttemptAt == nil)
                #expect(row.leaseExpiresAt == nil)
                #expect(row.sourceTokenHash == nil)
                #expect(row.sourceTokenExpiresAt == nil)
                #expect(row.terminalNotifiedAt == nil)
            }
        }
    }

    @Test
    func `expired public source token returns not found`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client, prefix: "ing-token")
            let batch = try await Self.createFileBatch(client: client, token: auth.accessToken, bytes: Data("token".utf8))
            let itemID = try #require(batch.items.first?.id)
            let token = String(repeating: "a", count: 64)

            try await withTestFluent(label: "ingestion.token.seed") { fluent in
                let item = try #require(try await IngestionItem.find(itemID, on: fluent.db()))
                item.sourceTokenHash = MultimodalIngestionService.sourceTokenHash(token)
                item.sourceTokenExpiresAt = Date().addingTimeInterval(-1)
                try await item.save(on: fluent.db())
            }

            try await client.execute(uri: "/v1/ingestion-sources/\(token)", method: .get) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test
    func `expired worker lease is recovered after a simulated crash`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client, prefix: "ing-crash")
            let batch = try await Self.createFileBatch(client: client, token: auth.accessToken, bytes: Data("crash".utf8))
            let itemID = try #require(batch.items.first?.id)

            try await withTestFluent(label: "ingestion.crash.recover") { fluent in
                let item = try #require(try await IngestionItem.find(itemID, on: fluent.db()))
                item.state = IngestionItemStateDTO.extracting.rawValue
                item.leaseExpiresAt = Date().addingTimeInterval(-1)
                try await item.save(on: fluent.db())
                let sql = try #require(fluent.db() as? any SQLDatabase)

                try await MultimodalIngestionService.recoverExpiredWork(sql: sql)

                let recovered = try #require(try await IngestionItem.find(itemID, on: fluent.db()))
                #expect(recovered.state == IngestionItemStateDTO.queued.rawValue)
                #expect(recovered.leaseExpiresAt == nil)
                #expect(recovered.errorMessage == "Recovered after an interrupted worker lease")
            }
        }
    }
}
