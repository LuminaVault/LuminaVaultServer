@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Apple selective-sync — DB-backed controller tests for `POST /v1/calendar/sync`.
///
/// Same shape as `AppleRemindersControllerTests` (insert / update / idempotent /
/// last-writer-wins / 403) plus Calendar-specifics: cancelled events are
/// tombstoned (status preserved, not rejected) and rows are written with
/// `source = "apple_eventkit"` so they never collide with Google `source` rows.
///
/// Counts are asserted on the returned `AppleSyncResponse`. Because the upsert
/// key is `(tenant_id, source, external_id)` and this controller only ever
/// writes `source = "apple_eventkit"`, a re-sync of the same externalID that
/// resolves to `updated` (not `inserted`) is the observable proof the row was
/// keyed under the EventKit source.
///
/// Encoding contract (CRITICAL): camelCase keys + ISO-8601 dates — the server
/// decoder does not snake-case. Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase)
struct AppleCalendarControllerTests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("cal-\(suffix)@test.luminavault", "cal-\(suffix)")
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
    private static func sync(
        client: some TestClientProtocol,
        token: String,
        events: [AppleCalendarEventInput],
        expectStatus: HTTPResponse.Status = .ok
    ) async throws -> AppleSyncResponse? {
        let body = try wireEncoder.encode(AppleCalendarSyncRequest(events: events))
        return try await client.execute(
            uri: "/v1/calendar/sync",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: body)
        ) { response in
            #expect(response.status == expectStatus)
            guard response.status == .ok else { return nil }
            return try decodeSyncResponse(response.body)
        }
    }

    private static func event(
        _ externalID: String,
        title: String = "Standup",
        status: String? = nil,
        remoteUpdatedAt: Date? = nil
    ) -> AppleCalendarEventInput {
        let start = Date()
        return AppleCalendarEventInput(
            externalID: externalID,
            calendarID: "work",
            title: title,
            startsAt: start,
            endsAt: start.addingTimeInterval(1800),
            status: status,
            remoteUpdatedAt: remoteUpdatedAt
        )
    }

    // MARK: - Tests

    @Test
    func `403 when calendar consent not granted`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.sync(
                client: client,
                token: token,
                events: [Self.event("e-1")],
                expectStatus: .forbidden
            )
        }
    }

    @Test
    func `happy path inserts two events`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .calendar, allowed: true)

            let now = Date()
            let resp = try await Self.sync(client: client, token: token, events: [
                Self.event("e-1", remoteUpdatedAt: now),
                Self.event("e-2", remoteUpdatedAt: now),
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
            try await Self.setConsent(client: client, token: token, domain: .calendar, allowed: true)

            let t0 = Date()
            let first = try await Self.sync(client: client, token: token, events: [
                Self.event("e-1", remoteUpdatedAt: t0),
                Self.event("e-2", remoteUpdatedAt: t0),
            ])
            #expect(first?.inserted == 2)

            // Re-send same externalIDs (under source=apple_eventkit) with a newer
            // timestamp ⇒ updates, never re-inserts. Proves the EventKit source key.
            let t1 = t0.addingTimeInterval(60)
            let second = try await Self.sync(client: client, token: token, events: [
                Self.event("e-1", title: "Standup moved", remoteUpdatedAt: t1),
                Self.event("e-2", title: "Standup moved", remoteUpdatedAt: t1),
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
            try await Self.setConsent(client: client, token: token, domain: .calendar, allowed: true)

            let base = Date()
            let insert = try await Self.sync(client: client, token: token, events: [
                Self.event("e-lww", title: "Original", remoteUpdatedAt: base),
            ])
            #expect(insert?.inserted == 1)

            // OLDER ⇒ stale delta rejected (skipped).
            let older = try await Self.sync(client: client, token: token, events: [
                Self.event("e-lww", title: "Stale", remoteUpdatedAt: base.addingTimeInterval(-3600)),
            ])
            #expect(older?.updated == 0)
            #expect(older?.skipped == 1)

            // NEWER ⇒ accepted (updated).
            let newer = try await Self.sync(client: client, token: token, events: [
                Self.event("e-lww", title: "Fresh", remoteUpdatedAt: base.addingTimeInterval(3600)),
            ])
            #expect(newer?.updated == 1)
            #expect(newer?.skipped == 0)
        }
    }

    @Test
    func `cancelled event is tombstoned not rejected`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .calendar, allowed: true)

            let now = Date()
            // A cancelled event must still be stored (status="cancelled"), so it
            // upserts as a normal insert — not a skip.
            let resp = try await Self.sync(client: client, token: token, events: [
                Self.event("e-cancel", title: "Cancelled meeting", status: "cancelled", remoteUpdatedAt: now),
            ])
            #expect(resp?.inserted == 1)
            #expect(resp?.skipped == 0)

            // Re-sending the tombstone with a newer timestamp updates the same row.
            let again = try await Self.sync(client: client, token: token, events: [
                Self.event("e-cancel", title: "Cancelled meeting", status: "cancelled", remoteUpdatedAt: now.addingTimeInterval(60)),
            ])
            #expect(again?.updated == 1)
        }
    }

    @Test
    func `eventkit rows do not collide with other sources`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: token, domain: .calendar, allowed: true)

            // First sync inserts under source=apple_eventkit.
            let now = Date()
            let first = try await Self.sync(client: client, token: token, events: [
                Self.event("ext-shared", title: "EventKit copy", remoteUpdatedAt: now),
            ])
            #expect(first?.inserted == 1)

            // A second sync of the SAME externalID resolves to update (not insert),
            // confirming this controller consistently keys under one source. If it
            // wrote under a different/empty source the second call would insert.
            let second = try await Self.sync(client: client, token: token, events: [
                Self.event("ext-shared", title: "EventKit copy v2", remoteUpdatedAt: now.addingTimeInterval(30)),
            ])
            #expect(second?.inserted == 0)
            #expect(second?.updated == 1)
        }
    }

    @Test
    func `tenant isolation keeps each user's rows independent`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tokenA = try await Self.registerAndAuth(client: client)
            let tokenB = try await Self.registerAndAuth(client: client)
            try await Self.setConsent(client: client, token: tokenA, domain: .calendar, allowed: true)
            try await Self.setConsent(client: client, token: tokenB, domain: .calendar, allowed: true)

            let now = Date()
            let a = try await Self.sync(client: client, token: tokenA, events: [
                Self.event("shared-evt", title: "A's event", remoteUpdatedAt: now),
            ])
            #expect(a?.inserted == 1)

            // Same externalID + source for B is an insert (tenant-scoped key).
            let b = try await Self.sync(client: client, token: tokenB, events: [
                Self.event("shared-evt", title: "B's event", remoteUpdatedAt: now),
            ])
            #expect(b?.inserted == 1)
            #expect(b?.updated == 0)
        }
    }
}
