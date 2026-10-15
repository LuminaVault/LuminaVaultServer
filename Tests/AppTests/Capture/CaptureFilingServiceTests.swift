@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

/// Suggesting a Space for an unfiled note: only ever one of the user's own
/// Spaces, only while the note is unfiled, and never a move.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct CaptureFilingServiceTests {
    /// Answers every completion with `reply` and counts the calls.
    private final class StubTransport: HermesChatTransport, @unchecked Sendable {
        let reply: String
        private(set) var calls = 0
        init(reply: String) {
            self.reply = reply
        }

        func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            calls += 1
            let outer: [String: Any] = ["choices": [["message": ["role": "assistant", "content": reply]]]]
            return try JSONSerialization.data(withJSONObject: outer)
        }
    }

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"file-\#(suffix)@test.luminavault","username":"file\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
    }

    /// One unfiled note on disk and in `vault_files`, plus a "work" Space.
    private static func seed(fluent: Fluent, tenantID: UUID, root: URL) async throws -> (file: UUID, space: UUID) {
        let space = Space(tenantID: tenantID, name: "Work", slug: "work", description: "Job, team, deploys")
        try await space.save(on: fluent.db())
        let path = "inbox/standup.md"
        let target = root.appendingPathComponent("tenants/\(tenantID.uuidString)/raw/\(path)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Standup moved to 9:30 for the whole team.".utf8).write(to: target)
        let file = VaultFile(
            tenantID: tenantID, path: path, contentType: "text/markdown", sizeBytes: 40,
            sha256: String(repeating: "a", count: 64)
        )
        try await file.save(on: fluent.db())
        return try (file.requireID(), space.requireID())
    }

    private static func service(fluent: Fluent, root: URL, reply: String) -> (CaptureFilingService, StubTransport) {
        let transport = StubTransport(reply: reply)
        let service = CaptureFilingService(
            fluent: fluent,
            transport: transport,
            vaultPaths: VaultPathService(rootPath: root.path),
            defaultModel: "test-model",
            logger: Logger(label: "test.autofile")
        )
        return (service, transport)
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lv-autofile-\(UUID().uuidString)")
    }

    @Test
    func `a fitting Space is suggested, shown in the list, and nothing moves`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await withTestFluent(label: "test.autofile.fit") { fluent in
                let root = Self.tempRoot()
                let (fileID, spaceID) = try await Self.seed(fluent: fluent, tenantID: auth.userId, root: root)
                let (service, _) = Self.service(fluent: fluent, root: root, reply: #"{"space":"work"}"#)

                let slug = try await service.suggest(tenantID: auth.userId, fileID: fileID)
                #expect(slug == "work")

                let file = try #require(try await VaultFile.query(on: fluent.db(), tenantID: auth.userId)
                    .filter(\.$id == fileID).first())
                #expect(file.metadata?.suggestedSpaceID == spaceID)
                #expect(file.spaceID == nil, "a suggestion must not file anything")
                #expect(file.path == "inbox/standup.md")
                #expect(try VaultFileDTO.fromRow(file).metadata?.suggestedSpaceId == spaceID)
            }
        }
    }

    @Test
    func `none, an invented Space, or an already-filed note give no suggestion`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await withTestFluent(label: "test.autofile.none") { fluent in
                let root = Self.tempRoot()
                let (fileID, spaceID) = try await Self.seed(fluent: fluent, tenantID: auth.userId, root: root)

                for reply in [#"{"space":"none"}"#, #"{"space":"finance"}"#, "I think Work."] {
                    let (service, _) = Self.service(fluent: fluent, root: root, reply: reply)
                    #expect(try await service.suggest(tenantID: auth.userId, fileID: fileID) == nil, "\(reply)")
                }

                let file = try #require(try await VaultFile.query(on: fluent.db(), tenantID: auth.userId)
                    .filter(\.$id == fileID).first())
                #expect(file.metadata?.suggestedSpaceID == nil)

                file.spaceID = spaceID
                try await file.save(on: fluent.db())
                let (service, transport) = Self.service(fluent: fluent, root: root, reply: #"{"space":"work"}"#)
                #expect(try await service.suggest(tenantID: auth.userId, fileID: fileID) == nil)
                #expect(transport.calls == 0, "a filed note costs no model call")
            }
        }
    }

    @Test
    func `the reply parser accepts JSON in prose and fences`() {
        #expect(CaptureFilingService.parseSuggestion(#"{"space":"Work"}"#) == "work")
        #expect(CaptureFilingService.parseSuggestion("```json\n{\"space\":\"ops\"}\n```") == "ops")
        #expect(CaptureFilingService.parseSuggestion(#"Sure: {"space":"none"}"#) == nil)
        #expect(CaptureFilingService.parseSuggestion("") == nil)
    }
}
