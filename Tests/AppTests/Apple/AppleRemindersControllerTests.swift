@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Apple selective-sync — DB-backed controller tests for `POST /v1/reminders/sync`.
///
/// Mirrors `HealthReadTests`: boots the full app via HummingbirdTesting,
/// registers a user for a JWT, grants consent via `PUT /v1/apple/consent`,
/// then drives the ingest endpoint and asserts on the `AppleSyncResponse`
/// counts returned across successive calls (insert / update / skip).
///
/// Encoding contract (CRITICAL): the server request decoder does NOT apply
/// `convertFromSnakeCase`, so request bodies are encoded as camelCase keys +
/// ISO-8601 dates by re-using the shared DTO types with a plain `JSONEncoder`
/// (`.iso8601`). Snake-casing would silently nil-decode server-side.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase)
struct AppleRemindersControllerTests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("rem-\(suffix)@test.luminavault", "rem-\(suffix)")
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

    /// Grants (or revokes) one Apple consent domain via the same PUT the client uses.
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

    /// POSTs a reminders batch and returns the decoded counts. `expectStatus`
    /// lets the 403 path assert without decoding.
    @discardableResult
    private static func sync(
        client: some TestClientProtocol,
        token: String,
        reminders: [AppleReminderInput],
        expectStatus: HTTPResponse.Status = .ok
    ) async throws -> AppleSyncResponse? {
        let body = try wireEncoder.encode(AppleRemindersSyncRequest(reminders: reminders))
        return try await client.execute(
            uri: "/v1/reminders/sync",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: body)
        ) { response in
            #expect(response.status == expectStatus)
            guard response.status == .ok else { return nil }
            return try decodeSyncResponse(response.body)
        }
    }

    // MARK: - Tests

    @Test
    func `403 when reminders consent not granted`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.sync(
                client: client,
                token: token,
                reminders: [AppleReminderInput(externalID: "r-1", title: "Buy milk")],
                expectStatus: .forbidden
            )
        }
    }

    @Test
    func `happy path inserts two reminders`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .reminders, allowed: true)

            let now = Date()
            let resp = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "r-1", title: "Buy milk", remoteUpdatedAt: now),
                AppleReminderInput(externalID: "r-2", title: "Call mom", remoteUpdatedAt: now),
            ])
            #expect(resp?.inserted == 2)
            #expect(resp?.updated == 0)
            #expect(resp?.skipped == 0)
        }
    }

    @Test
    func `idempotent re-sync updates existing rows`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .reminders, allowed: true)

            let t0 = Date()
            let first = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "r-1", title: "Buy milk", remoteUpdatedAt: t0),
                AppleReminderInput(externalID: "r-2", title: "Call mom", remoteUpdatedAt: t0),
            ])
            #expect(first?.inserted == 2)

            // Same externalIDs, a newer timestamp ⇒ both rows update, none inserted.
            let t1 = t0.addingTimeInterval(60)
            let second = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "r-1", title: "Buy oat milk", remoteUpdatedAt: t1),
                AppleReminderInput(externalID: "r-2", title: "Call mom back", remoteUpdatedAt: t1),
            ])
            #expect(second?.inserted == 0)
            #expect(second?.updated == 2)
            #expect(second?.skipped == 0)
        }
    }

    @Test
    func `last writer wins on remoteUpdatedAt`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .reminders, allowed: true)

            let base = Date()
            let insert = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "r-lww", title: "Original", remoteUpdatedAt: base),
            ])
            #expect(insert?.inserted == 1)

            // OLDER timestamp ⇒ stale delta rejected (skipped), row unchanged.
            let older = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "r-lww", title: "Stale edit", remoteUpdatedAt: base.addingTimeInterval(-3600)),
            ])
            #expect(older?.updated == 0)
            #expect(older?.skipped == 1)

            // NEWER timestamp ⇒ accepted (updated).
            let newer = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "r-lww", title: "Fresh edit", remoteUpdatedAt: base.addingTimeInterval(3600)),
            ])
            #expect(newer?.updated == 1)
            #expect(newer?.skipped == 0)
        }
    }

    @Test
    func `skips malformed rows with empty externalID`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .reminders, allowed: true)

            let now = Date()
            let resp = try await Self.sync(client: client, token: token, reminders: [
                AppleReminderInput(externalID: "  ", title: "No id", remoteUpdatedAt: now),
                AppleReminderInput(externalID: "r-ok", title: "Valid", remoteUpdatedAt: now),
            ])
            #expect(resp?.inserted == 1)
            #expect(resp?.skipped == 1)
        }
    }

    @Test
    func `tenant isolation keeps each user's rows independent`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tokenA = try await Self.registerAndAuth(client: client)
            let tokenB = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: tokenA, domain: .reminders, allowed: true)
            try await Self.setConsent(client: client, token: tokenB, domain: .reminders, allowed: true)

            let now = Date()
            // User A seeds two rows with externalIDs that User B will also use.
            let a = try await Self.sync(client: client, token: tokenA, reminders: [
                AppleReminderInput(externalID: "shared-1", title: "A one", remoteUpdatedAt: now),
                AppleReminderInput(externalID: "shared-2", title: "A two", remoteUpdatedAt: now),
            ])
            #expect(a?.inserted == 2)

            // User B sends the SAME externalIDs — because the upsert key is
            // (tenant_id, external_id) these are inserts for B, not updates of A.
            let b = try await Self.sync(client: client, token: tokenB, reminders: [
                AppleReminderInput(externalID: "shared-1", title: "B one", remoteUpdatedAt: now),
                AppleReminderInput(externalID: "shared-2", title: "B two", remoteUpdatedAt: now),
            ])
            #expect(b?.inserted == 2)
            #expect(b?.updated == 0)

            // A re-sends with a newer timestamp — still updates only A's rows.
            let aAgain = try await Self.sync(client: client, token: tokenA, reminders: [
                AppleReminderInput(externalID: "shared-1", title: "A one v2", remoteUpdatedAt: now.addingTimeInterval(120)),
            ])
            #expect(aAgain?.inserted == 0)
            #expect(aAgain?.updated == 1)
        }
    }
}
