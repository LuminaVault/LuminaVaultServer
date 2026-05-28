@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-118 — end-to-end tests for `GET /v1/health/daily`. Boots the full
/// app so JWT auth, query parsing, SQL aggregation, and gap-fill all run.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct HealthDailyAggregateTests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("hd-\(suffix)@test.luminavault", "hd-\(suffix)")
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeIngestResponse(_ buffer: ByteBuffer) throws -> HealthIngestResponse {
        try testJSONDecoder().decode(HealthIngestResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeDailyResponse(_ buffer: ByteBuffer) throws -> HealthDailyResponse {
        try testJSONDecoder().decode(HealthDailyResponse.self, from: Data(buffer: buffer))
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

    private struct IngestPayload: Encodable {
        let events: [LuminaVaultShared.HealthEventInput]
    }

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

    private static func fetchDaily(
        client: some TestClientProtocol,
        token: String,
        type: String,
        days: Int? = nil,
    ) async throws -> HealthDailyResponse {
        var uri = "/v1/health/daily?type=\(type)"
        if let days {
            uri += "&days=\(days)"
        }
        return try await client.execute(
            uri: uri,
            method: .get,
            headers: [.authorization: "Bearer \(token)"],
        ) { try decodeDailyResponse($0.body) }
    }

    // MARK: - Tests

    @Test
    func `steps aggregation sums daily values`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            // Three samples today, two samples yesterday.
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now, valueNumeric: 1200, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now.addingTimeInterval(-3600), valueNumeric: 800, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now.addingTimeInterval(-7200), valueNumeric: 400, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now.addingTimeInterval(-86400 - 3600), valueNumeric: 5000, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now.addingTimeInterval(-86400 - 7200), valueNumeric: 3000, unit: "count"),
            ])

            let result = try await Self.fetchDaily(client: client, token: token, type: "steps")
            #expect(result.type == "steps")
            #expect(result.days.count == 7)
            // Today bucket (last entry, chronological ascending) sums to 2400.
            let today = try #require(result.days.last)
            #expect(today.value == 2400)
            #expect(today.sampleCount == 3)
            // Yesterday bucket sums to 8000.
            let yesterday = result.days[result.days.count - 2]
            #expect(yesterday.value == 8000)
            #expect(yesterday.sampleCount == 2)
        }
    }

    @Test
    func `hr aggregation averages daily values`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "hr_bpm", recordedAt: now, valueNumeric: 60, unit: "bpm"),
                LuminaVaultShared.HealthEventInput(type: "hr_bpm", recordedAt: now.addingTimeInterval(-3600), valueNumeric: 80, unit: "bpm"),
                LuminaVaultShared.HealthEventInput(type: "hr_bpm", recordedAt: now.addingTimeInterval(-7200), valueNumeric: 100, unit: "bpm"),
            ])

            let result = try await Self.fetchDaily(client: client, token: token, type: "hr_bpm")
            let today = try #require(result.days.last)
            // (60 + 80 + 100) / 3 = 80
            #expect(abs(today.value - 80) < 0.001)
            #expect(today.sampleCount == 3)
        }
    }

    @Test
    func `gap days return zero value and zero sample count`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let now = Date()
            // Only seed today; expect 6 zero-filled gap days.
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now, valueNumeric: 500, unit: "count"),
            ])

            let result = try await Self.fetchDaily(client: client, token: token, type: "steps")
            #expect(result.days.count == 7)
            // Sort ascending: gap days first, then today.
            let nonZero = result.days.filter { $0.sampleCount > 0 }
            let zero = result.days.filter { $0.sampleCount == 0 }
            #expect(nonZero.count == 1)
            #expect(zero.count == 6)
            for gap in zero {
                #expect(gap.value == 0)
            }
        }
    }

    @Test
    func `custom days parameter returns matching window length`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let result = try await Self.fetchDaily(client: client, token: token, type: "steps", days: 14)
            #expect(result.days.count == 14)
        }
    }

    @Test
    func `days out of range returns 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/health/daily?type=steps&days=0",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(
                uri: "/v1/health/daily?type=steps&days=91",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `missing type query parameter returns 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/health/daily",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `tenant isolation other-user samples not returned`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.registerAndAuth(client: client)
            let bob = try await Self.registerAndAuth(client: client)
            let now = Date()
            try await Self.seedEvents(client: client, token: alice, events: [
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: now, valueNumeric: 9999, unit: "count"),
            ])
            let bobResult = try await Self.fetchDaily(client: client, token: bob, type: "steps")
            for day in bobResult.days {
                #expect(day.value == 0)
                #expect(day.sampleCount == 0)
            }
        }
    }
}
