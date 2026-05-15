@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-202 — end-to-end tests for `GET /v1/health`. The route mirrors
/// `MemoryController::list` and reuses the existing JWT auth path; tests
/// boot the full app so middleware, decoding, and Fluent paging are all
/// exercised. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct HealthReadTests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("hr-\(suffix)@test.luminavault", "hr-\(suffix)")
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeIngestResponse(_ buffer: ByteBuffer) throws -> HealthIngestResponse {
        try testJSONDecoder().decode(HealthIngestResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeListResponse(_ buffer: ByteBuffer) throws -> HealthListResponse {
        try testJSONDecoder().decode(HealthListResponse.self, from: Data(buffer: buffer))
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
            body: body,
        ) { try decodeAuthResponse($0.body) }
        return resp.accessToken
    }

    /// Wire-format payload for the ingest request. The server's struct is
    /// `internal` and shadowed by the shared `HealthEventInput`, so we
    /// encode the wire shape directly from the test-local typealias below.
    private struct IngestPayload: Encodable {
        let events: [LuminaVaultShared.HealthEventInput]
    }

    /// Seeds health events directly via `POST /v1/health` so the test
    /// path matches what the iOS client will do in production.
    @discardableResult
    private static func seedEvents(
        client: some TestClientProtocol,
        token: String,
        events: [LuminaVaultShared.HealthEventInput],
    ) async throws -> HealthIngestResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyData = try encoder.encode(IngestPayload(events: events))
        return try await client.execute(
            uri: "/v1/health",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: bodyData),
        ) { try decodeIngestResponse($0.body) }
    }

    /// `ISO8601DateFormatter` is documented thread-safe; `nonisolated(unsafe)`
    /// is the standard Swift 6 escape hatch for these legacy Foundation types.
    nonisolated(unsafe) private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Tests

    @Test
    func `lists most recent events within default 7 day window`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now, valueNumeric: 1200, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now.addingTimeInterval(-3600), valueNumeric: 800, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now.addingTimeInterval(-3 * 86_400), valueNumeric: 4000, unit: "count"),
            ])

            try await client.execute(
                uri: "/v1/health",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeListResponse(response.body)
                #expect(list.events.count == 3)
                // DESC by recordedAt — freshest first.
                let descending = zip(list.events, list.events.dropFirst())
                    .allSatisfy { $0.0.recordedAt >= $0.1.recordedAt }
                #expect(descending)
                #expect(list.limit == 100)
                #expect(list.offset == 0)
            }
        }
    }

    @Test
    func `filters by type`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now, valueNumeric: 1200, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "hr_bpm", recordedAt: now.addingTimeInterval(-60), valueNumeric: 72, unit: "bpm"),
            ])

            try await client.execute(
                uri: "/v1/health?type=steps",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeListResponse(response.body)
                #expect(!list.events.isEmpty)
                #expect(list.events.allSatisfy { $0.type == "steps" })
            }
        }
    }

    @Test
    func `applies from to window`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "weight_kg", recordedAt: thirtyDaysAgo, valueNumeric: 80.0, unit: "kg"),
            ])

            // Default 7-day window should NOT include the 30-day-old event.
            try await client.execute(
                uri: "/v1/health?type=weight_kg",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeListResponse(response.body)
                #expect(list.events.isEmpty)
            }

            // Explicit window covering the 30-day-old event must return it.
            let from = Self.isoFmt.string(from: now.addingTimeInterval(-40 * 86_400))
            let to = Self.isoFmt.string(from: now)
            try await client.execute(
                uri: "/v1/health?type=weight_kg&from=\(from)&to=\(to)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeListResponse(response.body)
                #expect(list.events.count == 1)
                #expect(list.events.first?.valueNumeric == 80.0)
            }
        }
    }

    @Test
    func `clamps limit to bounds`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            // Above-max → clamps to 200.
            try await client.execute(
                uri: "/v1/health?limit=10000",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeListResponse(response.body)
                #expect(list.limit == 200)
            }

            // Below-min → clamps to 1.
            try await client.execute(
                uri: "/v1/health?limit=0",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeListResponse(response.body)
                #expect(list.limit == 1)
            }
        }
    }

    @Test
    func `offset paginates stably`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            // 10 events, 1 minute apart so DESC order is deterministic.
            let events = (0 ..< 10).map { i in
                LuminaVaultShared.HealthEventInput(
                    type: "steps",
                    recordedAt: now.addingTimeInterval(-Double(i) * 60),
                    valueNumeric: Double(1000 + i),
                    unit: "count",
                )
            }
            try await Self.seedEvents(client: client, token: token, events: events)

            let page1: HealthListResponse = try await client.execute(
                uri: "/v1/health?type=steps&limit=4&offset=0",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) {
                #expect($0.status == .ok)
                return try Self.decodeListResponse($0.body)
            }
            let page2: HealthListResponse = try await client.execute(
                uri: "/v1/health?type=steps&limit=4&offset=4",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) {
                #expect($0.status == .ok)
                return try Self.decodeListResponse($0.body)
            }

            #expect(page1.events.count == 4)
            #expect(page2.events.count == 4)
            #expect(page1.offset == 0)
            #expect(page2.offset == 4)

            let ids1 = Set(page1.events.map(\.id))
            let ids2 = Set(page2.events.map(\.id))
            #expect(ids1.isDisjoint(with: ids2))

            // Both pages still DESC.
            for page in [page1, page2] {
                let descending = zip(page.events, page.events.dropFirst())
                    .allSatisfy { $0.0.recordedAt >= $0.1.recordedAt }
                #expect(descending)
            }
        }
    }
}
