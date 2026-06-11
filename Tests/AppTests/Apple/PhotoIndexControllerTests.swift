@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Apple selective-sync — tests for `POST /v1/photos/index`.
///
/// Two layers:
///   1. Pure unit tests for `PhotoIndexController.embedSource` — no DB, always run.
///   2. DB-backed integration tests mirroring `HealthReadTests` /
///      `AppleRemindersControllerTests`: boot the full app, register a user for a
///      JWT, grant `.photos` consent via `PUT /v1/apple/consent`, then assert on
///      the `AppleSyncResponse` counts. Run with `docker compose up -d postgres`.
///
/// Encoding contract (CRITICAL): the server request decoder does NOT apply
/// `convertFromSnakeCase`, so request bodies are encoded camelCase + ISO-8601 by
/// re-using the shared DTO types with a plain `JSONEncoder` (`.iso8601`).
@Suite(.serialized)
struct PhotoIndexControllerTests {
    // MARK: - Pure unit tests (no DB)

    @Test
    func `embedSource is nil when ocr and tags are both empty`() {
        #expect(PhotoIndexController.embedSource(ocr: nil, tags: nil) == nil)
        #expect(PhotoIndexController.embedSource(ocr: "   ", tags: []) == nil)
        #expect(PhotoIndexController.embedSource(ocr: "", tags: nil) == nil)
    }

    @Test
    func `embedSource uses ocr text when present`() {
        #expect(PhotoIndexController.embedSource(ocr: "Flight AB123 gate 7", tags: nil) == "Flight AB123 gate 7")
    }

    @Test
    func `embedSource prefixes scene tags`() {
        let out = PhotoIndexController.embedSource(ocr: nil, tags: ["receipt", "document"])
        #expect(out == "Scene: receipt, document")
    }

    @Test
    func `embedSource combines ocr then scene tags`() {
        let out = PhotoIndexController.embedSource(ocr: "Total $42.10", tags: ["receipt"])
        #expect(out == "Total $42.10\nScene: receipt")
    }

    // MARK: - DB-backed helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("pho-\(suffix)@test.luminavault", "pho-\(suffix)")
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeSyncResponse(_ buffer: ByteBuffer) throws -> AppleSyncResponse {
        try testJSONDecoder().decode(AppleSyncResponse.self, from: Data(buffer: buffer))
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let body = ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try decodeAuthResponse($0.body) }
        return resp.accessToken
    }

    /// camelCase + ISO-8601 encoder — the wire contract the server decoder expects.
    private nonisolated(unsafe) static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static func setConsent(
        client: some TestClientProtocol,
        token: String,
        domain: AppleDataDomain,
        allowed: Bool
    ) async throws {
        let body = try wireEncoder.encode(AppleConsentUpdateRequest(domain: domain, allowed: allowed))
        try await client.execute(
            uri: "/v1/apple/consent",
            method: .put,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: body)
        ) { #expect($0.status == .ok) }
    }

    @discardableResult
    private static func index(
        client: some TestClientProtocol,
        token: String,
        items: [PhotoIndexInput],
        expectStatus: HTTPResponse.Status = .ok
    ) async throws -> AppleSyncResponse? {
        let body = try wireEncoder.encode(PhotoIndexSyncRequest(items: items))
        return try await client.execute(
            uri: "/v1/photos/index",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: body)
        ) { response in
            #expect(response.status == expectStatus)
            guard response.status == .ok else { return nil }
            return try decodeSyncResponse(response.body)
        }
    }

    // MARK: - DB-backed tests

    @Test
    func `403 when photos consent not granted`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.index(
                client: client,
                token: token,
                items: [PhotoIndexInput(assetLocalID: "asset-1", isScreenshot: true, ocrText: "hi")],
                expectStatus: .forbidden
            )
        }
    }

    @Test
    func `happy path inserts two items`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .photos, allowed: true)

            let resp = try await Self.index(client: client, token: token, items: [
                PhotoIndexInput(assetLocalID: "asset-1", takenAt: Date(), isScreenshot: true, ocrText: "Flight AB123"),
                // No OCR / tags ⇒ stored with NULL embedding, but still upserted.
                PhotoIndexInput(assetLocalID: "asset-2", takenAt: Date(), isScreenshot: false),
            ])
            #expect(resp?.inserted == 2)
            #expect(resp?.updated == 0)
            #expect(resp?.skipped == 0)
        }
    }

    @Test
    func `idempotent re-index updates by assetLocalID`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .photos, allowed: true)

            let first = try await Self.index(client: client, token: token, items: [
                PhotoIndexInput(assetLocalID: "asset-x", isScreenshot: true, ocrText: "v1"),
            ])
            #expect(first?.inserted == 1)

            let second = try await Self.index(client: client, token: token, items: [
                PhotoIndexInput(assetLocalID: "asset-x", isScreenshot: true, ocrText: "v2", sceneTags: ["receipt"]),
            ])
            #expect(second?.inserted == 0)
            #expect(second?.updated == 1)
        }
    }

    @Test
    func `skips items with empty assetLocalID`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .photos, allowed: true)

            let resp = try await Self.index(client: client, token: token, items: [
                PhotoIndexInput(assetLocalID: "  ", isScreenshot: false, ocrText: "no id"),
                PhotoIndexInput(assetLocalID: "asset-ok", isScreenshot: true, ocrText: "ok"),
            ])
            #expect(resp?.inserted == 1)
            #expect(resp?.skipped == 1)
        }
    }

    @Test
    func `tenant isolation keeps each user's photo rows independent`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tokenA = try await Self.registerAndAuth(client: client)
            let tokenB = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: tokenA, domain: .photos, allowed: true)
            try await Self.setConsent(client: client, token: tokenB, domain: .photos, allowed: true)

            // Same assetLocalID for both users — the upsert key is
            // (tenant_id, asset_local_id), so each is an insert, not a cross-update.
            let a = try await Self.index(client: client, token: tokenA, items: [
                PhotoIndexInput(assetLocalID: "shared-asset", isScreenshot: true, ocrText: "A"),
            ])
            #expect(a?.inserted == 1)

            let b = try await Self.index(client: client, token: tokenB, items: [
                PhotoIndexInput(assetLocalID: "shared-asset", isScreenshot: true, ocrText: "B"),
            ])
            #expect(b?.inserted == 1)
            #expect(b?.updated == 0)
        }
    }
}
