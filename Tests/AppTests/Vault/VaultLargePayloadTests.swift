@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.MemoryListResponse
import struct LuminaVaultShared.VaultUploadResponse
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct VaultLargePayloadTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(testPassword)"}
        """)
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let response = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: "vault-large-\(suffix)@test.luminavault", username: "vault-large-\(suffix)")
        ) { response in
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
        return response.accessToken
    }

    private static func upload(
        client: some TestClientProtocol,
        token: String,
        path: String,
        body: ByteBuffer,
        contentType: String,
        note: Bool = false
    ) async throws -> VaultUploadResponse {
        let noteQuery = note ? "&note=true" : ""
        return try await client.execute(
            uri: "/v1/vault/files?path=\(path)\(noteQuery)",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: contentType],
            body: body
        ) { response in
            #expect(response.status == .ok || response.status == .created)
            return try testJSONDecoder().decode(VaultUploadResponse.self, from: Data(buffer: response.body))
        }
    }

    @Test
    func `large upload can be read back through file endpoint`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            var payload = Data()
            let chunk = Data("0123456789abcdef".utf8)
            for _ in 0 ..< 128 * 1024 {
                payload.append(chunk)
            }

            let upload = try await Self.upload(
                client: client,
                token: token,
                path: "captures/large.txt",
                body: ByteBuffer(data: payload),
                contentType: "text/plain"
            )
            #expect(upload.size == payload.count)

            try await client.execute(
                uri: "/v1/vault/files/\(upload.path)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentLength] == String(payload.count))
                #expect(Data(buffer: response.body) == payload)
            }
        }
    }

    @Test
    func `note upload still creates memory through background queue`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let content = "queued note memory \(UUID().uuidString)"
            _ = try await Self.upload(
                client: client,
                token: token,
                path: "notes/queued.md",
                body: ByteBuffer(string: content),
                contentType: "text/markdown",
                note: true
            )

            var found = false
            for _ in 0 ..< 20 {
                try await Task.sleep(for: .milliseconds(100))
                found = try await client.execute(
                    uri: "/v1/memory?limit=20",
                    method: .get,
                    headers: [.authorization: "Bearer \(token)"]
                ) { response in
                    #expect(response.status == .ok)
                    let list = try testJSONDecoder().decode(MemoryListResponse.self, from: Data(buffer: response.body))
                    return list.memories.contains(where: { $0.content == content })
                }
                if found {
                    break
                }
            }
            #expect(found)
        }
    }
}
