@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// `GET /v1/me/today` over the real router, JWT and Postgres.
///
/// HER-206 shipped `MeTodayService.fetchHealthSummary` as raw SQL that no
/// test ever ran against a real database. It selected `type` from
/// `health_events`, a column that has never existed — `M14_CreateHealthEvent`
/// creates `event_type` — so every call returned 500 with
/// `42703 column "type" does not exist`, and the Today surface on web and in
/// the widget was dead. These tests exist to keep the aggregate honest about
/// the schema it reads.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeTodayControllerTests {
    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"today-\(suffix)@test.luminavault","username":"today-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
        return resp.accessToken
    }

    private struct IngestPayload: Encodable {
        let events: [LuminaVaultShared.HealthEventInput]
    }

    private static func seedEvents(
        client: some TestClientProtocol,
        token: String,
        events: [LuminaVaultShared.HealthEventInput]
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyData = try encoder.encode(IngestPayload(events: events))
        try await client.execute(
            uri: "/v1/health",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: bodyData)
        ) { response in
            #expect(response.status == .ok)
        }
    }

    private static func decodeToday(_ buffer: ByteBuffer) throws -> MeTodayResponse {
        try testJSONDecoder().decode(MeTodayResponse.self, from: Data(buffer: buffer))
    }

    // MARK: - Tests

    /// The regression that took the surface down: a tenant with no health
    /// rows at all still runs both health statements, so the bad column name
    /// 500s before any data question is even asked.
    @Test
    func `returns the aggregate for a tenant with no data`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            try await client.execute(
                uri: "/v1/me/today",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let today = try Self.decodeToday(response.body)
                #expect(today.healthSummary == nil)
                #expect(today.openSpacesCount >= 0)
                #expect(today.unlockedAchievementsToday.isEmpty)
            }
        }
    }

    /// Steps are summed for the current day only. Yesterday's row must not
    /// leak into today's total.
    @Test
    func `sums today's steps and excludes yesterday`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            // Anchor inside today so the assertion cannot straddle midnight
            // in the way a `Date()`-relative offset can.
            let noonToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: noonToday, valueNumeric: 1200, unit: "count"),
                LuminaVaultShared.HealthEventInput(type: "steps", recordedAt: noonToday.addingTimeInterval(3600), valueNumeric: 800, unit: "count"),
                LuminaVaultShared.HealthEventInput(
                    type: "steps",
                    recordedAt: noonToday.addingTimeInterval(-86400),
                    valueNumeric: 9999,
                    unit: "count"
                ),
            ])

            try await client.execute(
                uri: "/v1/me/today",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let today = try Self.decodeToday(response.body)
                #expect(today.healthSummary?.stepsToday == 2000)
            }
        }
    }

    /// Last night's sleep comes from `sleep_session` — the event type the
    /// iOS client actually writes, in minutes. The aggregate previously
    /// asked for `sleep_minutes`, which nothing has ever produced, so the
    /// field would have stayed nil even with the column name fixed.
    @Test
    func `reports last night's sleep from sleep_session minutes`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let dayStart = Calendar.current.startOfDay(for: Date())
            // 23:00 yesterday — inside the [dayStart - 24h, dayStart) window.
            let lastNight = dayStart.addingTimeInterval(-3600)
            try await Self.seedEvents(client: client, token: token, events: [
                LuminaVaultShared.HealthEventInput(
                    type: "sleep_session",
                    recordedAt: lastNight,
                    valueNumeric: 450,
                    unit: "minutes"
                ),
            ])

            try await client.execute(
                uri: "/v1/me/today",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let today = try Self.decodeToday(response.body)
                #expect(today.healthSummary?.sleepLastNight == "PT7H30M")
            }
        }
    }
}
