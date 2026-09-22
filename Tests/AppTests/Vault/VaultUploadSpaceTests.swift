@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-CaptureTab — covers the optional `space_id` upload query param.
/// New behaviour: link the uploaded `vault_files` row to a Space the
/// caller owns; reject malformed UUIDs and cross-tenant ids with 400;
/// preserve the existing link on re-upload when omitted.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct VaultUploadSpaceTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("vault-cap-\(suffix)@test.luminavault", "vault-cap-\(suffix)")
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: testPassword)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
        return resp.accessToken
    }

    // HER-235: fully qualify `LuminaVaultShared.SpaceDTO` to disambiguate
    // from `App.SpaceDTO` (typealias to `Components.Schemas.SpaceDTO`).
    // The wire shapes are equivalent; the shared type is the API contract.
    private static func createSpace(
        client: some TestClientProtocol,
        token: String,
        name: String
    ) async throws -> LuminaVaultShared.SpaceDTO {
        try await client.execute(
            uri: "/v1/spaces",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: """
            {"name":"\(name)"}
            """)
        ) { response in
            #expect(response.status == .ok || response.status == .created)
            return try decodeReporting(LuminaVaultShared.SpaceDTO.self, from: response)
        }
    }

    @discardableResult
    private static func uploadRaw(
        client: some TestClientProtocol,
        token: String,
        path: String,
        spaceIDRaw: String? = nil,
        body: String = "# capture"
    ) async throws -> (status: HTTPResponse.Status, body: ByteBuffer) {
        var uri = "/v1/vault/files?path=\(path)"
        if let spaceIDRaw {
            uri += "&space_id=\(spaceIDRaw)"
        }
        return try await client.execute(
            uri: uri,
            method: .post,
            headers: [
                .authorization: "Bearer \(token)",
                .contentType: "text/markdown",
            ],
            body: ByteBuffer(string: body)
        ) { (response: TestResponse) in
            (response.status, response.body)
        }
    }

    private static func listFiles(
        client: some TestClientProtocol,
        token: String
    ) async throws -> [VaultFileDTO] {
        try await client.execute(
            uri: "/v1/vault/files",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            #expect(response.status == .ok)
            return try decodeReporting(VaultFileListResponse.self, from: response).files
        }
    }

    @Test
    func `upload with valid space_id sets spaceId on the row`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let space = try await Self.createSpace(client: client, token: token, name: "Capture")

            let (status, _) = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "capture/note.md",
                spaceIDRaw: space.id.uuidString
            )
            #expect(status == .ok)

            let files = try await Self.listFiles(client: client, token: token)
            let row = try #require(files.first { $0.path == "capture/note.md" })
            #expect(row.spaceId == space.id)
        }
    }

    @Test
    func `upload without space_id leaves spaceId nil`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let (status, _) = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "unfiled/note.md"
            )
            #expect(status == .ok)

            // HER-105: the client's path prefix is advisory. The server files
            // an upload under its Space's slug and an unfiled one under
            // `inbox`, keeping only the basename, so the on-disk vault mirrors
            // Spaces rather than whatever the caller happened to send.
            let files = try await Self.listFiles(client: client, token: token)
            let row = try #require(files.first { $0.path == "inbox/note.md" })
            #expect(row.spaceId == nil)
            #expect(files.contains { $0.path == "unfiled/note.md" } == false)
        }
    }

    @Test
    func `upload with malformed space_id returns 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let (status, _) = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "bad/note.md",
                spaceIDRaw: "not-a-uuid"
            )
            #expect(status == .badRequest)
        }
    }

    @Test
    func `upload with cross-tenant space_id returns 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.registerAndAuth(client: client)
            let bob = try await Self.registerAndAuth(client: client)
            let aliceSpace = try await Self.createSpace(client: client, token: alice, name: "AliceOnly")

            let (status, _) = try await Self.uploadRaw(
                client: client,
                token: bob,
                path: "bob/leak.md",
                spaceIDRaw: aliceSpace.id.uuidString
            )
            #expect(status == .badRequest)
        }
    }

    /// Renamed from "re-upload with new space_id overwrites previous link".
    /// It does not overwrite, and has not since HER-105 made the storage path
    /// a function of the Space. The same basename sent to a second Space
    /// lands beside the first as its own file — moving a note between Spaces
    /// is a move, not an upload. The old name described the behaviour this
    /// endpoint had before the path rule changed.
    @Test
    func `uploading the same name to a second space files it under that space`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let spaceA = try await Self.createSpace(client: client, token: token, name: "SpaceA")
            let spaceB = try await Self.createSpace(client: client, token: token, name: "SpaceB")

            _ = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "shared/path.md",
                spaceIDRaw: spaceA.id.uuidString
            )
            _ = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "shared/path.md",
                spaceIDRaw: spaceB.id.uuidString
            )

            let files = try await Self.listFiles(client: client, token: token)
            let inA = try #require(files.first { $0.path == "\(spaceA.slug)/path.md" })
            let inB = try #require(files.first { $0.path == "\(spaceB.slug)/path.md" })
            #expect(inA.spaceId == spaceA.id)
            #expect(inB.spaceId == spaceB.id)
            #expect(files.contains { $0.path == "shared/path.md" } == false)
        }
    }

    /// The filed copy keeps its Space. The unfiled re-upload does not reach
    /// it, because without a `space_id` the server files by `inbox` rather
    /// than by the caller's prefix — so this is two rows, not one updated one.
    @Test
    func `re-upload omitting space_id leaves the filed copy alone`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let space = try await Self.createSpace(client: client, token: token, name: "Preserved")

            _ = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "keep/path.md",
                spaceIDRaw: space.id.uuidString
            )
            _ = try await Self.uploadRaw(
                client: client,
                token: token,
                path: "keep/path.md",
                spaceIDRaw: nil,
                body: "# updated content"
            )

            let files = try await Self.listFiles(client: client, token: token)
            let filed = try #require(files.first { $0.path == "\(space.slug)/path.md" })
            #expect(filed.spaceId == space.id)
            let unfiled = try #require(files.first { $0.path == "inbox/path.md" })
            #expect(unfiled.spaceId == nil)
        }
    }
}
