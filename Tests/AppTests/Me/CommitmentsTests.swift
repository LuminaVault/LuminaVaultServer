@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// Commitments ("open loops"): the lenient `commitments` parse of the
/// kb-compile response — pure, no database.
struct CommitmentParsingTests {
    @Test
    func `valid commitments keep text, due day and source`() {
        let raw = """
        {"memories": [], "commitments": [
          {"text": "Send Ana the deck", "due": "2026-10-23", "source": "notes/a.md"},
          {"text": "  Renew passport  ", "due": null},
          {"text": "Call the bank", "due": "2026-10-24T09:30:00Z"}
        ]}
        """
        let items = MemoryCompileService.parseExtractedCommitments(raw)
        #expect(items.map(\.text) == ["Send Ana the deck", "Renew passport", "Call the bank"])
        #expect(items[0].source == "notes/a.md")
        #expect(items[0].due == ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        #expect(items[1].due == nil)
        #expect(items[2].due == ISO8601DateFormatter().date(from: "2026-10-24T09:30:00Z"))
    }

    @Test
    func `a missing or malformed commitments key is no commitments`() {
        #expect(MemoryCompileService.parseExtractedCommitments(#"{"memories": ["a"]}"#).isEmpty)
        #expect(MemoryCompileService.parseExtractedCommitments(#"{"memories": [], "commitments": "soon"}"#).isEmpty)
        #expect(MemoryCompileService.parseExtractedCommitments(#"["a", "b"]"#).isEmpty)
        #expect(MemoryCompileService.parseExtractedCommitments("not json at all").isEmpty)
        #expect(MemoryCompileService.parseExtractedCommitments("").isEmpty)
        // Entries without usable text are skipped, not fatal.
        let mixed = MemoryCompileService.parseExtractedCommitments(#"{"commitments": [{"due": "2026-10-23"}, {"text": "  "}, 7, {"text": "Book the dentist"}]}"#)
        #expect(mixed.map(\.text) == ["Book the dentist"])
    }

    @Test
    func `an unparsable due is nil and the commitment is kept`() {
        let items = MemoryCompileService.parseExtractedCommitments("""
        ```json
        {"commitments": [
          {"text": "Pay rent", "due": "Friday"},
          {"text": "Water plants", "due": "2026-02-30"},
          {"text": "Fix bike", "due": 20261023}
        ]}
        ```
        """)
        #expect(items.map(\.text) == ["Pay rent", "Water plants", "Fix bike"])
        #expect(items.allSatisfy { $0.due == nil })
    }

    @Test
    func `prose around the JSON is tolerated`() {
        let items = MemoryCompileService.parseExtractedCommitments(#"Here you go: {"memories": [], "commitments": [{"text": "Email Joe"}]} hope that helps"#)
        #expect(items.map(\.text) == ["Email Joe"])
    }

    @Test
    func `normalization folds case, spacing and trailing punctuation`() {
        #expect(CommitmentsService.normalize("  I'll   Call Mum. ") == "i'll call mum")
        #expect(CommitmentsService.normalize("i'll call mum!") == "i'll call mum")
    }
}

/// Commitments against Postgres: kb-compile stores them (deduped), and
/// `GET/PATCH /v1/me/commitments` serve the caller's own only.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct CommitmentsIntegrationTests {
    // MARK: - kb-compile

    @Test
    func `kb-compile stores commitments with their file and a recompile adds no duplicate`() async throws {
        try await withTestFluent(label: "test.commitments.compile") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let slug = "cm\(UUID().uuidString.prefix(8).lowercased())"
            let tenantID = try await saveTenant(User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "x"), on: fluent.db())
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lv-commit-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "notes/todo.md"
            let target = root.appendingPathComponent("tenants/\(tenantID.uuidString)/raw/\(path)")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("I'll send Ana the deck by Friday. I need to renew my passport.".utf8).write(to: target)
            let file = VaultFile(tenantID: tenantID, path: path, contentType: "text/markdown", sizeBytes: 60, sha256: String(repeating: "c", count: 64))
            try await file.save(on: fluent.db())

            let reply = #"{"memories": [{"text": "Renew passport", "kind": "note", "source": "notes/todo.md"}], "commitments": [{"text": "Send Ana the deck", "due": "2026-10-23", "source": "notes/todo.md"}, {"text": "Renew passport", "due": "someday", "source": "elsewhere.md"}]}"#
            let service = MemoryCompileService(
                vaultPaths: VaultPathService(rootPath: root.path),
                transport: StubCompletionTransport(content: reply),
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test-model",
                logger: Logger(label: "test.commitments.compile")
            )
            for _ in 0 ..< 2 {
                _ = try await service.compileExistingVaultFiles(tenantID: tenantID, sessionKey: slug, rows: [file], hint: nil, runId: UUID())
            }

            let open = try await CommitmentsService(fluent: fluent).list(tenantID: tenantID, filter: .open)
            #expect(open.count == 2, "the second compile must not add the same promises again")
            let deck = try #require(open.first { $0.text == "Send Ana the deck" })
            #expect(deck.sourceVaultFileId == file.id)
            #expect(deck.dueAt == ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
            #expect(deck.state == .open)
            #expect(deck.surfacedCount == 0)
            let passport = try #require(open.first { $0.text == "Renew passport" })
            #expect(passport.dueAt == nil)
            #expect(passport.sourceVaultFileId == nil, "a path outside the batch is not trusted")
            // Each compile saves the memory again (memories have no dedupe);
            // the commitment keeps the first one's id.
            let memories = try await Memory.query(on: fluent.db(), tenantID: tenantID).filter(\.$content == "Renew passport").all()
            let memoryID = try #require(passport.memoryId)
            #expect(memories.compactMap(\.id).contains(memoryID), "linked to the memory saying the same thing")
        }
    }

    @Test
    func `a compile reply without commitments still saves its memories`() async throws {
        try await withTestFluent(label: "test.commitments.none") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let slug = "cn\(UUID().uuidString.prefix(8).lowercased())"
            let tenantID = try await saveTenant(User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "x"), on: fluent.db())
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lv-commit-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "notes/x.md"
            let target = root.appendingPathComponent("tenants/\(tenantID.uuidString)/raw/\(path)")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Prefers tea.".utf8).write(to: target)
            let file = VaultFile(tenantID: tenantID, path: path, contentType: "text/markdown", sizeBytes: 12, sha256: String(repeating: "d", count: 64))
            try await file.save(on: fluent.db())
            let service = MemoryCompileService(
                vaultPaths: VaultPathService(rootPath: root.path),
                transport: StubCompletionTransport(content: #"{"memories": ["Prefers tea."], "commitments": [{"text": 42}]}"#),
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test-model",
                logger: Logger(label: "test.commitments.none")
            )
            let result = try await service.compileExistingVaultFiles(tenantID: tenantID, sessionKey: slug, rows: [file], hint: nil, runId: UUID())
            #expect(result.memories.count == 1)
            #expect(try await CommitmentsService(fluent: fluent).list(tenantID: tenantID, filter: .all).isEmpty)
        }
    }

    // MARK: - HTTP

    private struct Account {
        let userID: UUID
        let token: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"commit-\#(suffix)@test.luminavault","username":"commit\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func list(client: some TestClientProtocol, token: String, query: String = "") async throws -> (HTTPResponse.Status, [CommitmentDTO]) {
        try await client.execute(
            uri: "/v1/me/commitments\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, []) }
            return try (response.status, testJSONDecoder().decode(CommitmentsResponse.self, from: Data(response.body.readableBytesView)).items)
        }
    }

    private static func patch(client: some TestClientProtocol, token: String, id: UUID, state: String) async throws -> (HTTPResponse.Status, CommitmentDTO?) {
        try await client.execute(
            uri: "/v1/me/commitments/\(id.uuidString)",
            method: .patch,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"state":"\#(state)"}"#)
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(CommitmentDTO.self, from: Data(response.body.readableBytesView)))
        }
    }

    @Test
    func `list and patch are tenant scoped and patch moves state and done_at`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let other = try await Self.register(client: client)
            let (mine, theirs) = try await withTestFluent(label: "test.commitments.http") { fluent in
                let service = CommitmentsService(fluent: fluent)
                try await service.record(tenantID: me.userID, [
                    .init(text: "Later one", due: nil, memoryID: nil, sourceVaultFileID: nil),
                    .init(text: "Due one", due: Date().addingTimeInterval(86400), memoryID: nil, sourceVaultFileID: nil),
                ])
                try await service.record(tenantID: other.userID, [.init(text: "Not mine", due: nil, memoryID: nil, sourceVaultFileID: nil)])
                return try await (
                    service.list(tenantID: me.userID, filter: .open),
                    service.list(tenantID: other.userID, filter: .open)
                )
            }

            var (status, items) = try await Self.list(client: client, token: me.token)
            #expect(status == .ok)
            #expect(items.map(\.text) == ["Due one", "Later one"], "due first, then oldest")

            // Another tenant's id is a 404, and it is untouched.
            let foreign = try #require(theirs.first)
            #expect(try await Self.patch(client: client, token: me.token, id: foreign.id, state: "done").0 == .notFound)
            #expect(try await Self.list(client: client, token: other.token).1.map(\.state) == [.open])

            let due = try #require(mine.first { $0.text == "Due one" })
            let (doneStatus, done) = try await Self.patch(client: client, token: me.token, id: due.id, state: "done")
            #expect(doneStatus == .ok)
            #expect(done?.state == .done)
            #expect(done?.doneAt != nil)

            (status, items) = try await Self.list(client: client, token: me.token)
            #expect(items.map(\.text) == ["Later one"])
            #expect(try await Self.list(client: client, token: me.token, query: "?state=done").1.map(\.id) == [due.id])
            #expect(try await Self.list(client: client, token: me.token, query: "?state=all").1.count == 2)
            #expect(try await Self.list(client: client, token: me.token, query: "?state=dropped").1.isEmpty)
            #expect(try await Self.list(client: client, token: me.token, query: "?state=snoozed").0 == .badRequest)

            let (_, reopened) = try await Self.patch(client: client, token: me.token, id: due.id, state: "open")
            #expect(reopened?.state == .open)
            #expect(reopened?.doneAt == nil)
            #expect(try await Self.patch(client: client, token: me.token, id: due.id, state: "snoozed").0 == .badRequest)
        }
    }
}

/// An OpenAI-shaped completion whose `content` is fixed. No network, no key.
struct StubCompletionTransport: HermesChatTransport {
    let content: String

    func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        let body: [String: Any] = [
            "id": "chatcmpl-stub",
            "model": "stub-model",
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}
