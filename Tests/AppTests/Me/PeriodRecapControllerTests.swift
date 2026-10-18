@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// `GET /v1/me/recap/period` over the real router, JWT and Postgres: local
/// days at the timezone boundary, the comparison window, tags and Spaces,
/// and the themes card being claimed once and written by the worker through
/// a stub transport.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct PeriodRecapControllerTests {
    private struct Account {
        let userID: UUID
        let token: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"wrap-\#(suffix)@test.luminavault","username":"wrap\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
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
        query: String
    ) async throws -> (HTTPResponse.Status, PeriodRecapResponse?, String?) {
        try await client.execute(
            uri: "/v1/me/recap/period\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            let cache = response.headers[.cacheControl]
            guard response.status == .ok else { return (response.status, nil, cache) }
            let body = try testJSONDecoder().decode(PeriodRecapResponse.self, from: Data(response.body.readableBytesView))
            return (response.status, body, cache)
        }
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @discardableResult
    private static func memory(
        fluent: Fluent,
        tenantID: UUID,
        content: String,
        at: String,
        tags: [String] = [],
        spaceID: UUID? = nil,
        contribution: MemoryContributionInput = .legacy
    ) async throws -> UUID {
        let memory = try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: DeterministicEmbeddingService().embed(content, tenantID: tenantID),
            contribution: contribution
        )
        let id = try memory.requireID()
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("""
        UPDATE memories SET created_at = \(bind: date(at)), tags = \(bind: tags), space_id = \(bind: spaceID)
        WHERE id = \(bind: id)
        """).run()
        return id
    }

    private static func message(fluent: Fluent, conversationID: UUID, at: String) async throws {
        let message = ConversationMessage(conversationID: conversationID, role: .user, content: "What did I decide?")
        try await message.save(on: fluent.db())
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("UPDATE conversation_messages SET created_at = \(bind: date(at)) WHERE id = \(bind: message.requireID())").run()
    }

    /// A Los Angeles user with a busy March 2026, created back in 2025.
    private static func seedMarch(fluent: Fluent, userID: UUID) async throws {
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("""
        UPDATE users SET timezone = 'America/Los_Angeles', created_at = '2025-06-01T00:00:00Z' WHERE id = \(bind: userID)
        """).run()
        let space = Space(tenantID: userID, name: "Work", slug: "work-\(UUID().uuidString.prefix(6).lowercased())")
        try await space.save(on: fluent.db())
        let spaceID = try space.requireID()

        // 2–4 March, three captures each (PST is UTC-8).
        for day in 2 ... 4 {
            for hour in [16, 17, 18] {
                try await memory(
                    fluent: fluent,
                    tenantID: userID,
                    content: "Note \(day)-\(hour)\nbody",
                    at: String(format: "2026-03-%02dT%02d:00:00Z", day, hour),
                    tags: day == 2 ? ["Swift"] : ["swift", "side_project"],
                    spaceID: spaceID
                )
            }
        }
        // 23:30 on 31 March in Los Angeles is 1 April in UTC: still March.
        try await memory(fluent: fluent, tenantID: userID, content: "Late night", at: "2026-04-01T06:30:00Z")
        // 23:30 on 28 February in Los Angeles is 1 March in UTC: February.
        try await memory(fluent: fluent, tenantID: userID, content: "February", at: "2026-03-01T07:30:00Z")
        // A distilled memory counts as learned.
        try await memory(
            fluent: fluent,
            tenantID: userID,
            content: "Learned",
            at: "2026-03-03T20:00:00Z",
            contribution: .model(.create, source: .knowledgeCompile, provider: "hermes", model: "test")
        )

        let conversation = Conversation(tenantID: userID, title: "Plans")
        try await conversation.save(on: fluent.db())
        let conversationID = try conversation.requireID()
        try await sql.raw("UPDATE conversations SET created_at = '2026-03-03T18:00:00Z' WHERE id = \(bind: conversationID)").run()
        try await message(fluent: fluent, conversationID: conversationID, at: "2026-03-03T18:05:00Z")
        try await message(fluent: fluent, conversationID: conversationID, at: "2026-03-04T18:05:00Z")

        for _ in 0 ..< 2 {
            try await sql.raw("""
            INSERT INTO skill_run_log (id, tenant_id, source, name, started_at, status)
            VALUES (\(bind: UUID()), \(bind: userID), 'cron', 'daily-brief', '2026-03-10T12:00:00Z', 'ok')
            """).run()
        }
    }

    // MARK: - Tests

    @Test
    func `bad params are a 400 and a brand-new account has no recap yet`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let (bad, _, _) = try await Self.recap(client: client, token: account.token, query: "?period=week")
            #expect(bad == .badRequest)
            let (badMonth, _, _) = try await Self.recap(client: client, token: account.token, query: "?period=month&month=13")
            #expect(badMonth == .badRequest)

            let (status, recap, _) = try await Self.recap(client: client, token: account.token, query: "?period=year")
            #expect(status == .ok)
            let body = try #require(recap)
            #expect(!body.available)
            #expect(body.unavailableReason == .notEnoughActivity)
            #expect(body.order.isEmpty)

            let (_, old, _) = try await Self.recap(client: client, token: account.token, query: "?period=year&year=2020")
            #expect(old?.unavailableReason == .beforeAccount)
        }
    }

    @Test
    func `a month recap counts local days, compares with the month before and claims themes once`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            try await withTestFluent(label: "test.recap.period.seed") { fluent in
                try await Self.seedMarch(fluent: fluent, userID: account.userID)
            }

            let query = "?period=month&year=2026&month=3"
            let (status, recap, cache) = try await Self.recap(client: client, token: account.token, query: query)
            #expect(status == .ok)
            let body = try #require(recap)
            #expect(body.available)
            #expect(body.timezone == "America/Los_Angeles")
            #expect(body.isComplete)
            #expect(body.start == "2026-03-01")
            #expect(body.end == "2026-03-31")

            let captures = try #require(body.captures)
            #expect(captures.captures == 10)
            #expect(captures.learned == 1)
            #expect(captures.previousCaptures == 1)
            #expect(captures.series.count == 31)
            #expect(captures.series.first { $0.key == "2026-03-31" }?.count == 1)
            #expect(captures.series.first { $0.key == "2026-03-03" }?.count == 4)
            #expect(captures.firstCapture?.date == "2026-03-02")
            #expect(captures.firstCapture?.title == "Note 2-16")

            #expect(body.peak?.busiest == RecapBucketDTO(key: "2026-03-03", count: 4))
            #expect(body.streak?.longestDays == 3)
            #expect(body.streak?.longestStart == "2026-03-02")
            #expect(body.streak?.activeDays == 4)
            #expect(body.topics?.topTags.first == RecapCountDTO(label: "swift", count: 9))
            #expect(body.topics?.topTags.contains(RecapCountDTO(label: "side_project", count: 6)) == true)
            #expect(body.topics?.topSpace == RecapCountDTO(label: "Work", count: 9))
            #expect(body.chats == RecapChatsCardDTO(conversations: 1, messagesSent: 2, previousMessagesSent: 0))
            #expect(body.skills == RecapSkillsCardDTO(runs: 2, topSkill: RecapCountDTO(label: "daily-brief", count: 2)))
            // 08:00–10:00 local, plus 10:05 messages.
            #expect(body.rhythm?.persona == .earlyBird)

            #expect(body.order.contains(.themes))
            #expect(body.themes?.status == .pending)
            #expect(body.themes?.fallbackSentence == "A month of swift and side_project.")
            #expect(cache == "private, no-cache")
            #expect(body.shareText == "My March 2026 on LuminaVault: 11 memories, 2 questions asked, a 3-day streak.")
            #expect(!body.shareText.contains("swift"))

            // A second view does not claim again. The app's own worker may
            // already have tried (Hermes is unreachable here) and stored the
            // fallback, so the card is pending or fallback, but never re-claimed.
            let (_, again, _) = try await Self.recap(client: client, token: account.token, query: query)
            let secondStatus = try #require(again?.themes?.status)
            #expect(secondStatus == .pending || secondStatus == .fallback)
            let attempts = try await withTestFluent(label: "test.recap.period.attempts") { fluent in
                try await PeriodRecapThemesStore(fluent: fluent).load(userID: account.userID, periodKey: "2026-03")?.attempts
            }
            #expect(attempts == 1)
        }
    }

    @Test
    func `the worker writes the themes the next view shows, and a failed write falls back`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let query = "?period=month&year=2026&month=3"
            try await withTestFluent(label: "test.recap.period.worker.seed") { fluent in
                try await Self.seedMarch(fluent: fluent, userID: account.userID)
            }
            let (_, first, _) = try await Self.recap(client: client, token: account.token, query: query)
            #expect(first?.themes?.status == .pending)

            let transport = StubRecapTransport(reply: .content(
                #"{"headline":"Early bird builder","sentence":"You wrote about Swift before breakfast.","themes":["swift"]}"#
            ))
            try await withTestFluent(label: "test.recap.period.worker") { fluent in
                let worker = PeriodRecapThemesWorker(
                    store: PeriodRecapThemesStore(fluent: fluent),
                    generator: PeriodRecapThemesGenerator(transport: transport, model: "test", logger: Logger(label: "test")),
                    logger: Logger(label: "test")
                )
                await worker.process(PeriodRecapThemesJob(
                    userID: account.userID,
                    periodKey: "2026-03",
                    start: Self.date("2026-03-01T08:00:00Z"),
                    end: Self.date("2026-04-01T07:00:00Z"),
                    input: PeriodRecapThemesInput(
                        periodName: "March 2026",
                        kind: .month,
                        memories: 11,
                        asked: 2,
                        topTags: [],
                        topSpace: nil,
                        persona: nil,
                        busiest: nil
                    )
                ))
            }
            #expect(await transport.calls == 1)

            let (_, second, cache) = try await Self.recap(client: client, token: account.token, query: query)
            let themes = try #require(second?.themes)
            #expect(themes.status == .ready)
            #expect(themes.headline == "Early bird builder")
            #expect(themes.themes == ["swift"])
            #expect(cache == "private, max-age=3600")

            // A different period whose write fails shows the counted sentence.
            let failing = StubRecapTransport(reply: .error)
            try await withTestFluent(label: "test.recap.period.worker.fail") { fluent in
                let store = PeriodRecapThemesStore(fluent: fluent)
                #expect(try await store.claim(userID: account.userID, periodKey: "2026", now: Date()))
                #expect(try await store.claim(userID: account.userID, periodKey: "2026", now: Date()) == false)
                let worker = PeriodRecapThemesWorker(
                    store: store,
                    generator: PeriodRecapThemesGenerator(transport: failing, model: "test", logger: Logger(label: "test")),
                    logger: Logger(label: "test")
                )
                await worker.process(PeriodRecapThemesJob(
                    userID: account.userID,
                    periodKey: "2026",
                    start: Self.date("2026-01-01T08:00:00Z"),
                    end: Date(),
                    input: PeriodRecapThemesInput(
                        periodName: "2026",
                        kind: .year,
                        memories: 11,
                        asked: 2,
                        topTags: [],
                        topSpace: nil,
                        persona: nil,
                        busiest: nil
                    )
                ))
                let row = try await store.load(userID: account.userID, periodKey: "2026")
                #expect(row?.status == "fallback")
                #expect(row?.requested_at == nil)
            }
        }
    }
}
