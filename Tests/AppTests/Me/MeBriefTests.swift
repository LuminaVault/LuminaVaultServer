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

/// The skill's markdown → cards, and feedback ordering — pure, no database.
struct BriefSectionParsingTests {
    @Test
    func `bold labels and headings become cards; the greeting is dropped`() {
        let markdown = """
        Busy morning, dry week ahead.

        **Today**
        - 09:00 Standup

        **Weather** — 18°C and dry, no rain all week.

        ## Inbox needs a look
        - Ana: contract — wants a reply by Wednesday

        **Due:** Pay the electricity bill

        **On your mind**
        You were planning the Porto trip.
        """
        let sections = BriefComposer.sections(from: markdown)
        #expect(sections.map(\.kind) == [.today, .weather, .inbox, .other, .onYourMind])
        #expect(sections[1].body == "18°C and dry, no rain all week.")
        #expect(sections[3].title == "Due")
        #expect(sections[3].body == "Pay the electricity bill")
    }

    @Test
    func `text without labels is one on-your-mind card`() {
        let sections = BriefComposer.sections(from: "Quiet day. You wanted to call Sam back.")
        #expect(sections == [.init(kind: .onYourMind, title: "On your mind", body: "Quiet day. You wanted to call Sam back.")])
        #expect(BriefComposer.sections(from: "  \n ").isEmpty)
    }

    @Test
    func `bold emphasis inside a sentence is not a label, unknown headings are other`() {
        #expect(BriefComposer.label(in: "**Remember** to stretch today") == nil)
        #expect(BriefComposer.kind(forHeading: "Stocks") == .other)
        #expect(BriefComposer.kind(forHeading: "Forecast") == .weather)
    }

    @Test
    func `kinds with net feedback at or below minus two move to the bottom`() {
        let cards = [BriefCardKind.today, .openLoops, .weather, .inbox].map {
            BriefCardDTO(id: $0.rawValue, kind: $0, title: $0.rawValue, body: "b")
        }
        let ordered = BriefComposer.order(cards, net: ["today": -2, "weather": -1, "inbox": 3])
        #expect(ordered.map(\.kind) == [.openLoops, .weather, .inbox, .today])
    }
}

/// The daily brief against Postgres: composing, the commitment cap, feedback,
/// local days, tenant isolation and the shared proactive push budget.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeBriefIntegrationTests {
    private static let day: TimeInterval = 86400

    private static func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private static func migrated<T>(_ label: String, _ body: (Fluent) async throws -> T) async throws -> T {
        try await withTestFluent(label: label) { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            return try await body(fluent)
        }
    }

    private static func tenant(_ fluent: Fluent, timezone: String = "UTC") async throws -> UUID {
        let slug = "br\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "x")
        user.timezone = timezone
        return try await saveTenant(user, on: fluent.db())
    }

    private static func commitment(_ fluent: Fluent, tenantID: UUID, _ text: String, due: Date? = nil) async throws {
        try await CommitmentsService(fluent: fluent).record(tenantID: tenantID, [.init(text: text, due: due, memoryID: nil, sourceVaultFileID: nil)])
    }

    private static func surfaced(_ fluent: Fluent, tenantID: UUID) async throws -> [String: Int] {
        let items = try await CommitmentsService(fluent: fluent).list(tenantID: tenantID, filter: .all)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.text, $0.surfacedCount) })
    }

    // MARK: - Composing

    @Test
    func `cards come in order with a why each and the brief ends`() async throws {
        try await Self.migrated("test.brief.compose") { fluent in
            let now = Self.iso("2026-10-20T08:00:00Z")
            let tenantID = try await Self.tenant(fluent, timezone: "Europe/Lisbon")
            let sql = try #require(fluent.db() as? any SQLDatabase)
            try await sql.raw("""
            INSERT INTO apple_consent (tenant_id, domain, allowed, allow_writes, updated_at)
            VALUES (\(bind: tenantID), 'calendar', TRUE, FALSE, NOW())
            """).run()
            try await sql.raw("""
            INSERT INTO calendar_events (tenant_id, source, external_id, title, starts_at, ends_at)
            VALUES (\(bind: tenantID), 'apple_eventkit', 'e1', 'Dentist', \(bind: Self.iso("2026-10-20T14:00:00Z")), \(bind: Self.iso("2026-10-20T15:00:00Z"))),
                   (\(bind: tenantID), 'apple_eventkit', 'e2', 'Tomorrow thing', \(bind: Self.iso("2026-10-21T14:00:00Z")), \(bind: Self.iso("2026-10-21T15:00:00Z")))
            """).run()
            try await Self.commitment(fluent, tenantID: tenantID, "Send Ana the deck", due: now.addingTimeInterval(-Self.day))
            let due = try await MeLearnedTests.memory(fluent: fluent, tenantID: tenantID, content: "Old idea about gardens", createdAt: now.addingTimeInterval(-40 * Self.day), kind: nil)
            try await sql.raw("UPDATE memories SET next_review_at = \(bind: now.addingTimeInterval(-60)) WHERE id = \(bind: due)").run()
            try await MeLearnedTests.memory(fluent: fluent, tenantID: tenantID, content: "Prefers aisle seats", createdAt: now.addingTimeInterval(-Self.day), kind: .preference)

            let brief = try await BriefComposer(fluent: fluent).compose(
                tenantID: tenantID,
                skillMarkdown: "Morning!\n\n**Today**\n- 15:00 Dentist\n\n**Weather**\nDry.\n\n**Mystery**\nSomething else.",
                now: now
            )
            #expect(brief.date == "2026-10-20")
            #expect(brief.endNote == "That's it for today.")
            #expect(brief.cards.map(\.kind) == [.today, .openLoops, .toRevisit, .learned, .weather, .other])
            #expect(brief.cards.allSatisfy { !($0.why ?? "").isEmpty })
            let today = brief.cards[0]
            #expect(today.body == "- 15:00 · Dentist", "Lisbon time, today only")
            #expect(today.refs.map(\.kind) == [.event])
            #expect(brief.cards[1].why?.contains("overdue") == true)
            #expect(brief.cards[2].refs == [BriefCardRefDTO(kind: .memory, id: due.uuidString)])
            #expect(brief.cards[3].body.contains("1 thing about you"))
            #expect(brief.cards[5].title == "Mystery")

            let stored = try await MeBriefService(fluent: fluent).brief(tenantID: tenantID, date: "2026-10-20")
            #expect(stored == brief)
        }
    }

    @Test
    func `a commitment rides in at most three briefs and a same-day rerun counts once`() async throws {
        try await Self.migrated("test.brief.cap") { fluent in
            let tenantID = try await Self.tenant(fluent)
            try await Self.commitment(fluent, tenantID: tenantID, "Renew passport")
            let composer = BriefComposer(fluent: fluent)
            let day1 = Self.iso("2026-10-20T07:00:00Z")

            for rerun in 0 ..< 3 {
                let brief = try await composer.compose(tenantID: tenantID, skillMarkdown: "", now: day1.addingTimeInterval(Double(rerun) * 600))
                #expect(brief.cards.map(\.kind) == [.openLoops])
            }
            #expect(try await Self.surfaced(fluent, tenantID: tenantID) == ["Renew passport": 1])

            try await composer.compose(tenantID: tenantID, skillMarkdown: "", now: day1.addingTimeInterval(Self.day))
            let third = try await composer.compose(tenantID: tenantID, skillMarkdown: "", now: day1.addingTimeInterval(2 * Self.day))
            #expect(third.cards.map(\.kind) == [.openLoops])
            #expect(try await Self.surfaced(fluent, tenantID: tenantID) == ["Renew passport": 3])
            // Re-running the third day keeps it: that brief already paid for it.
            let thirdAgain = try await composer.compose(tenantID: tenantID, skillMarkdown: "", now: day1.addingTimeInterval(2 * Self.day + 3600))
            #expect(thirdAgain.cards.map(\.kind) == [.openLoops])
            #expect(thirdAgain.id == third.id)
            #expect(try await Self.surfaced(fluent, tenantID: tenantID) == ["Renew passport": 3])

            let fourth = try await composer.compose(tenantID: tenantID, skillMarkdown: "", now: day1.addingTimeInterval(3 * Self.day))
            #expect(fourth.cards.isEmpty, "no nagging after three briefs")
            #expect(try await CommitmentsService(fluent: fluent).list(tenantID: tenantID, filter: .open).count == 1, "still in the list")
        }
    }

    @Test
    func `the brief is per local day across a timezone boundary`() async throws {
        try await Self.migrated("test.brief.tz") { fluent in
            // Auckland is UTC+13 in October: 10:00Z is 23:00 on the 20th,
            // 12:00Z is 01:00 on the 21st.
            let tenantID = try await Self.tenant(fluent, timezone: "Pacific/Auckland")
            let composer = BriefComposer(fluent: fluent)
            let late = try await composer.compose(tenantID: tenantID, skillMarkdown: "One.", now: Self.iso("2026-10-20T10:00:00Z"))
            let early = try await composer.compose(tenantID: tenantID, skillMarkdown: "Two.", now: Self.iso("2026-10-20T12:00:00Z"))
            let lateAgain = try await composer.compose(tenantID: tenantID, skillMarkdown: "One again.", now: Self.iso("2026-10-20T10:30:00Z"))
            #expect(late.date == "2026-10-20")
            #expect(early.date == "2026-10-21")
            #expect(late.id != early.id)
            #expect(lateAgain.id == late.id, "same local day upserts the same brief")
            let stored = try await MeBriefService(fluent: fluent).brief(tenantID: tenantID, date: "2026-10-20")
            #expect(stored?.cards.first?.body == "One again.")
        }
    }

    @Test
    func `a kind marked down twice in 14 days moves to the bottom`() async throws {
        try await Self.migrated("test.brief.feedback.order") { fluent in
            let tenantID = try await Self.tenant(fluent)
            let composer = BriefComposer(fluent: fluent)
            let service = MeBriefService(fluent: fluent)
            let markdown = "**Weather**\nDry.\n\n**On your mind**\nPorto."
            let start = Self.iso("2026-10-10T07:00:00Z")
            var latest: BriefDTO?
            for offset in 0 ..< 2 {
                let now = start.addingTimeInterval(Double(offset) * Self.day)
                let brief = try await composer.compose(tenantID: tenantID, skillMarkdown: markdown, now: now)
                #expect(brief.cards.map(\.kind) == [.weather, .onYourMind])
                let action: BriefCardFeedbackAction = offset == 0 ? .down : .dismiss
                try await service.feedback(tenantID: tenantID, briefID: brief.id, cardID: "weather", action: action, actorUserID: tenantID, now: now)
                // A second tap on the same card replaces the first.
                try await service.feedback(tenantID: tenantID, briefID: brief.id, cardID: "weather", action: action, actorUserID: tenantID, now: now)
                latest = brief
            }
            _ = latest
            let demoted = try await composer.compose(tenantID: tenantID, skillMarkdown: markdown, now: start.addingTimeInterval(2 * Self.day))
            #expect(demoted.cards.map(\.kind) == [.onYourMind, .weather])
            // 14 days later the feedback has aged out.
            let later = try await composer.compose(tenantID: tenantID, skillMarkdown: markdown, now: start.addingTimeInterval(16 * Self.day))
            #expect(later.cards.map(\.kind) == [.weather, .onYourMind])
        }
    }

    @Test
    func `down on a to-revisit card snoozes the memory for 30 days`() async throws {
        try await Self.migrated("test.brief.feedback.later") { fluent in
            let tenantID = try await Self.tenant(fluent)
            let now = Date()
            let memoryID = try await MeLearnedTests.memory(fluent: fluent, tenantID: tenantID, content: "Revisit me", createdAt: now.addingTimeInterval(-40 * Self.day), kind: nil)
            let sql = try #require(fluent.db() as? any SQLDatabase)
            try await sql.raw("UPDATE memories SET next_review_at = \(bind: now.addingTimeInterval(-60)) WHERE id = \(bind: memoryID)").run()
            let brief = try await BriefComposer(fluent: fluent).compose(tenantID: tenantID, skillMarkdown: "", now: now)
            let card = try #require(brief.cards.first { $0.kind == .toRevisit })
            try await MeBriefService(fluent: fluent).feedback(tenantID: tenantID, briefID: brief.id, cardID: card.id, action: .down, actorUserID: tenantID, now: now)
            let memory = try #require(try await Memory.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == memoryID).first())
            let next = try #require(memory.nextReviewAt)
            #expect(abs(next.timeIntervalSince(now) - MemoryController.reviewLaterInterval) < 5)
            #expect(memory.resurfaceMuted == false)
        }
    }

    // MARK: - HTTP

    struct FeedbackRow: Decodable {
        let tenant_id: UUID
        let action: String
        let card_kind: String
    }

    private struct Account {
        let userID: UUID
        let token: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"brief-\#(suffix)@test.luminavault","username":"brief\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func getBrief(client: some TestClientProtocol, token: String, query: String = "") async throws -> (HTTPResponse.Status, MeBriefResponse?) {
        try await client.execute(
            uri: "/v1/me/brief\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(MeBriefResponse.self, from: Data(response.body.readableBytesView)))
        }
    }

    private static func postFeedback(client: some TestClientProtocol, token: String, briefID: UUID, cardID: String, action: String) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/v1/me/brief/\(briefID.uuidString)/cards/\(cardID)/feedback",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"action":"\#(action)"}"#)
        ) { $0.status }
    }

    @Test
    func `brief and feedback are the caller's own`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let other = try await Self.register(client: client)

            let (emptyStatus, empty) = try await Self.getBrief(client: client, token: me.token)
            #expect(emptyStatus == .ok)
            #expect(empty == MeBriefResponse(brief: nil), "no brief yet is null, not 404")

            let now = Date()
            let brief = try await withTestFluent(label: "test.brief.http") { fluent in
                try await BriefComposer(fluent: fluent).compose(tenantID: me.userID, skillMarkdown: "**Weather**\nDry.", now: now)
            }
            let (status, mine) = try await Self.getBrief(client: client, token: me.token, query: "?date=\(brief.date)")
            #expect(status == .ok)
            #expect(mine?.brief?.id == brief.id)
            #expect(try await Self.getBrief(client: client, token: me.token).1?.brief?.id == brief.id, "default is today")
            #expect(try await Self.getBrief(client: client, token: other.token, query: "?date=\(brief.date)").1 == MeBriefResponse(brief: nil))
            #expect(try await Self.getBrief(client: client, token: me.token, query: "?date=2026-13-01").0 == .badRequest)
            #expect(try await Self.getBrief(client: client, token: me.token, query: "?date=yesterday").0 == .badRequest)

            #expect(try await Self.postFeedback(client: client, token: other.token, briefID: brief.id, cardID: "weather", action: "down") == .notFound)
            #expect(try await Self.postFeedback(client: client, token: me.token, briefID: brief.id, cardID: "nope", action: "down") == .notFound)
            #expect(try await Self.postFeedback(client: client, token: me.token, briefID: brief.id, cardID: "weather", action: "meh") == .badRequest)
            #expect(try await Self.postFeedback(client: client, token: me.token, briefID: brief.id, cardID: "weather", action: "up") == .noContent)

            let rows = try await withTestFluent(label: "test.brief.http.rows") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                return try await sql.raw("SELECT tenant_id, action, card_kind FROM brief_feedback WHERE brief_id = \(bind: brief.id)").all(decoding: FeedbackRow.self)
            }
            #expect(rows.count == 1)
            #expect(rows.first?.tenant_id == me.userID)
            #expect(rows.first?.action == "up")
            #expect(rows.first?.card_kind == "weather")
        }
    }

    // MARK: - Delivery

    private static func runner(_ fluent: Fluent, push: RecordingPushSender, root: URL, reply: String) -> SkillRunner {
        let apns = APNSNotificationService(bundleID: "com.luminavault.test", fluent: fluent, pushSender: push, logger: Logger(label: "t"))
        let vaultPaths = VaultPathService(rootPath: root.path)
        return SkillRunner(
            catalog: SkillCatalog(vaultPaths: vaultPaths, logger: Logger(label: "t")),
            transport: StubCompletionTransport(content: reply),
            memories: MemoryRepository(fluent: fluent),
            embeddings: DeterministicEmbeddingService(),
            apns: apns,
            defaultModel: "test-model",
            fluent: fluent,
            vaultPaths: vaultPaths,
            capGuard: SkillRunCapGuard(fluent: fluent, logger: Logger(label: "t")),
            eventBus: EventBus(logger: Logger(label: "t")),
            proactiveChat: ProactiveChatDelivery(fluent: fluent, apns: apns, logger: Logger(label: "t")),
            briefComposer: BriefComposer(fluent: fluent),
            logger: Logger(label: "t")
        )
    }

    private static let dailyBrief = SkillManifest(
        source: .builtin, name: "daily-brief", description: "Morning brief",
        allowedTools: [], capability: .low, schedule: "0 7 * * *", onEvent: [],
        outputs: [.init(kind: .chatMessage, path: nil, category: nil)],
        dailyRunCap: nil, body: "Write the brief."
    )

    private static func hermieMessages(_ fluent: Fluent, tenantID: UUID) async throws -> [ConversationMessage] {
        guard let thread = try await Conversation.query(on: fluent.db(), tenantID: tenantID).filter(\.$systemKey == "hermie").first() else {
            return []
        }
        return try await ConversationMessage.query(on: fluent.db()).filter(\.$conversationID == thread.requireID()).all()
    }

    @Test
    func `the daily brief lands as cards, a one-line chat message and one quiet push`() async throws {
        try await Self.migrated("test.brief.delivery") { fluent in
            let tenantID = try await Self.tenant(fluent)
            let token = "tok-\(UUID().uuidString)"
            try await DeviceToken(tenantID: tenantID, token: token, platform: "ios").save(on: fluent.db())
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lv-brief-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let push = RecordingPushSender()
            let runner = Self.runner(fluent, push: push, root: root, reply: "Hi.\n\n**Weather**\nDry.\n\n**On your mind**\nPorto trip.")

            let result = try await runner.run(skill: Self.dailyBrief, tenantID: tenantID, profileUsername: "u", trigger: .cron)
            #expect(result.status == "ok")
            let today = ProactivePushBudget.localDay(Date(), timezone: "UTC")
            let brief = try #require(try await MeBriefService(fluent: fluent).brief(tenantID: tenantID, date: today))
            #expect(brief.cards.map(\.kind) == [.weather, .onYourMind])

            let messages = try await Self.hermieMessages(fluent, tenantID: tenantID)
            #expect(messages.map(\.content) == ["[Your brief is ready — 2 cards](luminavault://brief)"])
            let sends = await push.sends
            #expect(sends.count == 1)
            #expect(sends.first?.body == "Your brief is ready — 2 cards")
            #expect(sends.first?.payload["deepLink"] == "luminavault://brief")
            #expect(sends.first?.options.interruptionLevel == .passive)
            #expect(sends.first?.options.apsCategory == "brief")
            #expect(sends.first?.category == .chat)

            // A second run the same day: the brief is replaced, the message
            // lands, but today's proactive push is already spent.
            _ = try await runner.run(skill: Self.dailyBrief, tenantID: tenantID, profileUsername: "u", trigger: .cron)
            #expect(await push.sends.count == 1)
            #expect(try await Self.hermieMessages(fluent, tenantID: tenantID).count == 2)
        }
    }

    @Test
    func `the brief push is dropped when the learned digest already used today's slot`() async throws {
        try await Self.migrated("test.brief.budget") { fluent in
            let tenantID = try await Self.tenant(fluent)
            try await DeviceToken(tenantID: tenantID, token: "tok-\(UUID().uuidString)", platform: "ios").save(on: fluent.db())
            let won = try await ProactivePushBudget(fluent: fluent).claim(tenantID: tenantID, kind: LearnedDigestScheduler.budgetKind, timezone: "UTC")
            #expect(won)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lv-brief-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let push = RecordingPushSender()
            let runner = Self.runner(fluent, push: push, root: root, reply: "Quiet day.")

            _ = try await runner.run(skill: Self.dailyBrief, tenantID: tenantID, profileUsername: "u", trigger: .cron)
            #expect(await push.sends.isEmpty)
            #expect(try await Self.hermieMessages(fluent, tenantID: tenantID).map(\.content) == ["[Your brief is ready — 1 card](luminavault://brief)"])
            struct Row: Decodable { let kind: String }
            let sql = try #require(fluent.db() as? any SQLDatabase)
            let kinds = try await sql.raw("SELECT kind FROM proactive_push_log WHERE tenant_id = \(bind: tenantID)").all(decoding: Row.self)
            #expect(kinds.map(\.kind) == ["learned"])
        }
    }

    @Test
    func `the brief push leaves the budget alone when chat pushes are off`() async throws {
        try await Self.migrated("test.brief.optout") { fluent in
            let tenantID = try await Self.tenant(fluent)
            try await DeviceToken(tenantID: tenantID, token: "tok-\(UUID().uuidString)", platform: "ios").save(on: fluent.db())
            let sql = try #require(fluent.db() as? any SQLDatabase)
            try await sql.raw("INSERT INTO apns_category_prefs (tenant_id, chat_enabled) VALUES (\(bind: tenantID), FALSE)").run()
            let push = RecordingPushSender()
            let delivery = ProactiveChatDelivery(
                fluent: fluent,
                apns: APNSNotificationService(bundleID: "com.luminavault.test", fluent: fluent, pushSender: push, logger: Logger(label: "t")),
                logger: Logger(label: "t")
            )
            #expect(try await delivery.deliverBrief(tenantID: tenantID, cardCount: 3, sourceLabel: "daily-brief") == .optedOut)
            #expect(await push.sends.isEmpty)
            #expect(try await ProactivePushBudget(fluent: fluent).claim(tenantID: tenantID, kind: "learned", timezone: "UTC"), "the day's slot is still free")
        }
    }
}
