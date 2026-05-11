@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-88 end-to-end tests for vault list / delete / move endpoints.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct VaultCRUDTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeList(_ buffer: ByteBuffer) throws -> VaultFileListResponse {
        try testJSONDecoder().decode(VaultFileListResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeFile(_ buffer: ByteBuffer) throws -> VaultFileDTO {
        try testJSONDecoder().decode(VaultFileDTO.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("vault-\(suffix)@test.luminavault", "vault-\(suffix)")
    }

    /// Registers a user and returns the bearer token.
    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: testPassword),
        ) { try decodeAuthResponse($0.body) }
        return resp.accessToken
    }

    /// Uploads a markdown file. Returns the response path.
    @discardableResult
    private static func upload(
        client: some TestClientProtocol,
        token: String,
        path: String,
        body: String = "# hello",
    ) async throws -> String {
        let resp = try await client.execute(
            uri: "/v1/vault/files?path=\(path)",
            method: .post,
            headers: [
                .authorization: "Bearer \(token)",
                .contentType: "text/markdown",
            ],
            body: ByteBuffer(string: body),
        ) { response in
            #expect(response.status == .ok || response.status == .created)
            return try testJSONDecoder().decode(VaultUploadResponse.self, from: Data(buffer: response.body))
        }
        return resp.path
    }

    @Test
    func `list returns uploaded files`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "notes/a.md")
            _ = try await Self.upload(client: client, token: token, path: "notes/b.md")

            try await client.execute(
                uri: "/v1/vault/files",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.files.count >= 2)
                #expect(list.files.contains(where: { $0.path == "notes/a.md" }))
                #expect(list.files.contains(where: { $0.path == "notes/b.md" }))
            }
        }
    }

    @Test
    func `list limit clamps and paginates`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            for i in 0 ..< 3 {
                _ = try await Self.upload(client: client, token: token, path: "page-\(i).md")
            }
            try await client.execute(
                uri: "/v1/vault/files?limit=2",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.files.count == 2)
                #expect(list.limit == 2)
                #expect(list.nextBefore != nil)
            }
        }
    }

    @Test
    func `delete removes row and is tenant scoped`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.registerAndAuth(client: client)
            let mallory = try await Self.registerAndAuth(client: client)

            _ = try await Self.upload(client: client, token: alice, path: "alice-secret.md", body: "private")

            // Mallory cannot delete Alice's file.
            try await client.execute(
                uri: "/v1/vault/files/alice-secret.md",
                method: .delete,
                headers: [.authorization: "Bearer \(mallory)"],
            ) { #expect($0.status == .notFound) }

            // Alice can delete her own. Idempotent: second call returns 404.
            try await client.execute(
                uri: "/v1/vault/files/alice-secret.md",
                method: .delete,
                headers: [.authorization: "Bearer \(alice)"],
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: "/v1/vault/files/alice-secret.md",
                method: .delete,
                headers: [.authorization: "Bearer \(alice)"],
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test
    func `move renames file and updates row`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "old.md")

            let body = ByteBuffer(string: #"{"path":"old.md","newPath":"new.md"}"#)
            try await client.execute(
                uri: "/v1/vault/files/move",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .ok)
                let dto = try Self.decodeFile(response.body)
                #expect(dto.path == "new.md")
            }

            // List should expose new path, not old.
            try await client.execute(
                uri: "/v1/vault/files",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                let list = try Self.decodeList(response.body)
                #expect(list.files.contains(where: { $0.path == "new.md" }))
                #expect(!list.files.contains(where: { $0.path == "old.md" }))
            }
        }
    }

    @Test
    func `move rejects conflict`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "src.md")
            _ = try await Self.upload(client: client, token: token, path: "dst.md")
            let body = ByteBuffer(string: #"{"path":"src.md","newPath":"dst.md"}"#)
            try await client.execute(
                uri: "/v1/vault/files/move",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test
    func `move rejects traversal`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "in.md")
            let body = ByteBuffer(string: #"{"path":"in.md","newPath":"../escape.md"}"#)
            try await client.execute(
                uri: "/v1/vault/files/move",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test
    func `move rejects identical path`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "same.md")
            let body = ByteBuffer(string: #"{"path":"same.md","newPath":"same.md"}"#)
            try await client.execute(
                uri: "/v1/vault/files/move",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test
    func `tenant isolation list does not leak`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.registerAndAuth(client: client)
            let mallory = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: alice, path: "alice-only.md")

            try await client.execute(
                uri: "/v1/vault/files",
                method: .get,
                headers: [.authorization: "Bearer \(mallory)"],
            ) { response in
                let list = try Self.decodeList(response.body)
                #expect(!list.files.contains(where: { $0.path == "alice-only.md" }))
            }
        }
    }

    @Test
    func `list filter by unknown space returns 404`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/vault/files?space=does-not-exist",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test
    func `unauthenticated returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/vault/files", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/vault/files/foo.md", method: .delete) { #expect($0.status == .unauthorized) }
            try await client.execute(
                uri: "/v1/vault/files/move",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"path":"a.md","newPath":"b.md"}"#),
            ) { #expect($0.status == .unauthorized) }
        }
    }
}
