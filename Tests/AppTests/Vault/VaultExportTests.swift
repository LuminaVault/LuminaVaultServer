@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-91 end-to-end tests for `GET /v1/vault/export`.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct VaultExportTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("export-\(suffix)@test.luminavault", "export-\(suffix)")
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

    // MARK: - Tests

    @Test
    func `empty vault still includes soul and memories snapshots`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            try await client.execute(
                uri: "/v1/vault/export",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/zip")
                let bytes = Array(Data(buffer: response.body))
                try Self.assertValidZip(bytes: bytes)
                let names = try Self.entryNames(zip: bytes)
                #expect(names.contains("SOUL.md"))
                #expect(names.contains("memories.json"))
            }
        }
    }

    @Test
    func `export contains uploaded files`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "notes/a.md", body: "# a")
            _ = try await Self.upload(client: client, token: token, path: "notes/b.md", body: "# b")

            try await client.execute(
                uri: "/v1/vault/export",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let bytes = Array(Data(buffer: response.body))
                try Self.assertValidZip(bytes: bytes)
                let names = try Self.entryNames(zip: bytes)
                #expect(names.contains("raw/notes/a.md"))
                #expect(names.contains("raw/notes/b.md"))
            }
        }
    }

    @Test
    func `since filter excludes older files`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upload(client: client, token: token, path: "notes/old.md", body: "# old")

            // ISO timestamp in the future — should exclude everything.
            let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60 * 60))
            let encoded = future.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!

            try await client.execute(
                uri: "/v1/vault/export?since=\(encoded)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let bytes = Array(Data(buffer: response.body))
                try Self.assertValidZip(bytes: bytes)
                let names = try Self.entryNames(zip: bytes)
                #expect(!names.contains("raw/notes/old.md"))
                // SOUL.md + memories.json are always included.
                #expect(names.contains("SOUL.md"))
            }
        }
    }

    // MARK: - ZIP parsing helpers (minimal, EOCD + central-directory walk)

    private static func assertValidZip(bytes: [UInt8]) throws {
        // Local file header signature at offset 0.
        #expect(bytes.count >= 30)
        #expect(bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04)
        // EOCD signature somewhere in the last 22..(22+0xFFFF) bytes.
        #expect(findEOCD(bytes: bytes) != nil)
    }

    /// Walks the central directory and returns entry names in order.
    private static func entryNames(zip bytes: [UInt8]) throws -> [String] {
        guard let eocd = findEOCD(bytes: bytes) else { return [] }
        // EOCD: 4 sig + 2 disk + 2 cdDisk + 2 cdCount + 2 totalCount + 4 cdSize + 4 cdOffset + 2 comment
        let cdCount = Int(readUInt16(bytes, at: eocd + 10))
        let cdOffset = Int(readUInt32(bytes, at: eocd + 16))
        var cursor = cdOffset
        var names: [String] = []
        for _ in 0 ..< cdCount {
            // Central directory header signature 0x02014b50
            guard cursor + 46 <= bytes.count else { break }
            #expect(bytes[cursor] == 0x50 && bytes[cursor + 1] == 0x4B && bytes[cursor + 2] == 0x01 && bytes[cursor + 3] == 0x02)
            let nameLen = Int(readUInt16(bytes, at: cursor + 28))
            let extraLen = Int(readUInt16(bytes, at: cursor + 30))
            let commentLen = Int(readUInt16(bytes, at: cursor + 32))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart ..< nameEnd], as: UTF8.self)
            names.append(name)
            cursor = nameEnd + extraLen + commentLen
        }
        return names
    }

    private static func findEOCD(bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        // EOCD has variable-length comment (last 2 bytes), search backwards.
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
            if bytes.count - i > 22 + 0xFFFF { break }
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
