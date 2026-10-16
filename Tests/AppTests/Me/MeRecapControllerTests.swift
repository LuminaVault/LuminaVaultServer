@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// `GET /v1/me/recap` over the real router, JWT and Postgres: days are the
/// user's local days, missing days are zero-filled, and the share text never
/// carries what the user saved.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeRecapControllerTests {
    private struct Account {
        let userID: UUID
        let token: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"recap-\#(suffix)@test.luminavault","username":"recap\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func recap(
        client: some TestClientProtocol,
        token: String,
        query: String = ""
    ) async throws -> (HTTPResponse.Status, MeRecapResponse?) {
        try await client.execute(
            uri: "/v1/me/recap\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(MeRecapResponse.self, from: Data(response.body.readableBytesView)))
        }
    }

    @discardableResult
    private static func memory(
        fluent: Fluent,
        tenantID: UUID,
        content: String,
        at: Date? = nil,
        contribution: MemoryContributionInput = .legacy,
        kind: MemoryKindDTO? = nil
    ) async throws -> UUID {
        let memory = try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: DeterministicEmbeddingService().embed(content, tenantID: tenantID),
            contribution: contribution,
            kind: kind
        )
        let id = try memory.requireID()
        if let at, let sql = fluent.db() as? any SQLDatabase {
            try await sql.raw("UPDATE memories SET created_at = \(bind: at) WHERE id = \(bind: id)").run()
        }
        return id
    }

    private static func setTimezone(fluent: Fluent, userID: UUID, _ timezone: String) async throws {
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("UPDATE users SET timezone = \(bind: timezone) WHERE id = \(bind: userID)").run()
    }

    /// `yyyy-MM-dd` and the start of that day, `offset` days from today in `zone`.
    private static func localDay(_ offset: Int, in zone: String) -> (key: String, start: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
        let c = calendar.dateComponents([.year, .month, .day], from: start)
        return (String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), start)
    }

    // MARK: - Tests

    @Test
    func `counts a capture, a learned memory and a question on today and zero-fills the rest`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let secret = "Moving the launch to Lisbon \(UUID().uuidString.prefix(6))"
            let decisionID = try await withTestFluent(label: "test.recap.today") { fluent in
                try await Self.memory(fluent: fluent, tenantID: account.userID, content: secret)
                let decision = try await Self.memory(
                    fluent: fluent,
                    tenantID: account.userID,
                    content: "We ship on Tuesdays.\nBecause QA is Monday.",
                    contribution: .model(.create, source: .knowledgeCompile, provider: "hermes", model: "test"),
                    kind: .decision
                )
                let conversation = Conversation(tenantID: account.userID, title: "Plans")
                try await conversation.save(on: fluent.db())
                let conversationID = try conversation.requireID()
                try await ConversationMessage(conversationID: conversationID, role: .user, content: "When do we ship?")
                    .save(on: fluent.db())
                try await ConversationMessage(conversationID: conversationID, role: .assistant, content: "Tuesdays.")
                    .save(on: fluent.db())
                return decision
            }

            let (status, recap) = try await Self.recap(client: client, token: account.token)
            #expect(status == .ok)
            let body = try #require(recap)
            let today = Self.localDay(0, in: "UTC").key
            #expect(body.range == .week)
            #expect(body.timezone == "UTC")
            #expect(body.daily.count == 7)
            #expect(body.end == today)
            #expect(body.start == Self.localDay(-6, in: "UTC").key)
            #expect(body.daily.map(\.date) == (-6 ... 0).map { Self.localDay($0, in: "UTC").key })
            #expect(body.daily.last == RecapDayDTO(date: today, captures: 1, learned: 1, asked: 1, reviewed: 0))
            #expect(body.daily.dropLast().allSatisfy { $0 == RecapDayDTO(date: $0.date) })
            #expect(body.totals == RecapTotalsDTO(captures: 1, learned: 1, asked: 1, reviewed: 0, activeDays: 1, streakDays: 1))
            #expect(body.previousTotals == RecapTotalsDTO())
            #expect(body.kinds == RecapKindsDTO(decision: 1))
            let highlight = try #require(body.highlights.first { $0.kind == .decision })
            #expect(highlight.refId == decisionID.uuidString)
            #expect(highlight.title == "We ship on Tuesdays.")
            #expect(body.shareText == "My last 7 days on LuminaVault: 1 capture, 1 thing learned, 1 question asked, a 1-day streak.")
            #expect(!body.shareText.contains("Lisbon"))
            #expect(!body.shareText.contains("Tuesdays"))
        }
    }

    /// An event near UTC midnight lands on the user's local day, on both
    /// sides of UTC.
    @Test
    func `buckets by the user's local day`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            // UTC+14: 00:30 local is 10:30 the previous UTC day.
            let kiritimati = try await Self.register(client: client)
            let kiriDay = Self.localDay(-2, in: "Pacific/Kiritimati")
            // UTC-7/-8: 23:30 local is 06:30/07:30 the next UTC day.
            let angeles = try await Self.register(client: client)
            let laDay = Self.localDay(-2, in: "America/Los_Angeles")
            try await withTestFluent(label: "test.recap.tz") { fluent in
                try await Self.setTimezone(fluent: fluent, userID: kiritimati.userID, "Pacific/Kiritimati")
                try await Self.memory(
                    fluent: fluent, tenantID: kiritimati.userID, content: "early",
                    at: kiriDay.start.addingTimeInterval(30 * 60)
                )
                try await Self.setTimezone(fluent: fluent, userID: angeles.userID, "America/Los_Angeles")
                try await Self.memory(
                    fluent: fluent, tenantID: angeles.userID, content: "late",
                    at: laDay.start.addingTimeInterval(23.5 * 3600)
                )
            }

            let kiri = try #require(try await Self.recap(client: client, token: kiritimati.token).1)
            #expect(kiri.timezone == "Pacific/Kiritimati")
            #expect(kiri.end == Self.localDay(0, in: "Pacific/Kiritimati").key)
            #expect(kiri.daily.first { $0.date == kiriDay.key }?.captures == 1)
            #expect(kiri.totals.captures == 1)

            let la = try #require(try await Self.recap(client: client, token: angeles.token).1)
            #expect(la.timezone == "America/Los_Angeles")
            #expect(la.end == Self.localDay(0, in: "America/Los_Angeles").key)
            #expect(la.daily.first { $0.date == laDay.key }?.captures == 1)
            #expect(la.totals.captures == 1)
        }
    }

    @Test
    func `30d covers thirty days and the window before feeds previousTotals`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            try await withTestFluent(label: "test.recap.month") { fluent in
                // Eight days ago: outside this week, inside the week before.
                try await Self.memory(
                    fluent: fluent, tenantID: account.userID, content: "last week",
                    at: Self.localDay(-8, in: "UTC").start.addingTimeInterval(12 * 3600)
                )
            }

            let week = try #require(try await Self.recap(client: client, token: account.token, query: "?range=7d").1)
            #expect(week.daily.count == 7)
            #expect(week.totals.captures == 0)
            #expect(week.previousTotals.captures == 1)
            #expect(week.previousTotals.activeDays == 1)
            #expect(week.shareText == "My last 7 days on LuminaVault: 0 captures.")

            let month = try #require(try await Self.recap(client: client, token: account.token, query: "?range=30d").1)
            #expect(month.range == .month)
            #expect(month.daily.count == 30)
            #expect(month.start == Self.localDay(-29, in: "UTC").key)
            #expect(month.totals.captures == 1)
            #expect(month.previousTotals.captures == 0)
            #expect(month.shareText.hasPrefix("My last 30 days on LuminaVault: 1 capture"))
        }
    }

    @Test
    func `rejects a range that is not 7d or 30d`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            for query in ["?range=90d", "?range=week", "?range=1d"] {
                let (status, _) = try await Self.recap(client: client, token: account.token, query: query)
                #expect(status == .badRequest, "\(query)")
            }
        }
    }

    @Test
    func `share text pluralises and skips zero parts`() {
        #expect(MeRecapService.shareText(
            range: .week,
            totals: RecapTotalsDTO(captures: 12, learned: 9, asked: 31, streakDays: 5)
        ) == "My last 7 days on LuminaVault: 12 captures, 9 things learned, 31 questions asked, a 5-day streak.")
        #expect(MeRecapService.shareText(
            range: .month,
            totals: RecapTotalsDTO(captures: 0, learned: 0, asked: 2, streakDays: 0)
        ) == "My last 30 days on LuminaVault: 0 captures, 2 questions asked.")
    }
}
