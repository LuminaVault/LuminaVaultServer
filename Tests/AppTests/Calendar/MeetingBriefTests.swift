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

// MARK: - Words and matching (no database)

/// What the user reads — push title and body, the why line — is built from
/// counts and attendee names only, and the floor is a hard line.
struct MeetingBriefWordingTests {
    private static let ana = CalendarAttendeeDTO(name: "Ana Silva", email: "ana@example.com")
    private static let rui = CalendarAttendeeDTO(name: "Rui", email: "rui@example.com")
    private static let me = CalendarAttendeeDTO(name: "Fernando", email: "Me@Example.com")

    private static func event(title: String = "Q4 plan", notes: String? = nil, attendees: [CalendarAttendeeDTO] = []) -> MeetingBriefService.Event {
        MeetingBriefService.Event(
            id: UUID(),
            tenantID: UUID(),
            title: title,
            notes: notes,
            location: nil,
            startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 1800),
            attendees: attendees
        )
    }

    @Test
    func `the query is title, then names without the user, then notes`() {
        let query = MeetingBriefService.queryText(
            for: Self.event(title: "  Q4   plan ", notes: "Bring the\nhiring numbers", attendees: [Self.ana, Self.me, Self.rui, Self.ana]),
            selfEmail: "me@example.com"
        )
        #expect(query == "Q4 plan\nAna Silva, Rui\nBring the hiring numbers")
        #expect(MeetingBriefService.queryText(for: Self.event(title: ""), selfEmail: nil).isEmpty)
    }

    @Test
    func `long notes are cut so they do not drown the title`() {
        let query = MeetingBriefService.queryText(for: Self.event(notes: String(repeating: "dial in ", count: 500)), selfEmail: nil)
        #expect(query.count <= "Q4 plan\n".count + MeetingBriefService.maxNotesInQuery)
    }

    @Test
    func `names count notes that mention them, by whole word, ignoring case and accents`() {
        let mentioned = MeetingBriefService.mentionedNames(
            attendees: [Self.rui, Self.ana, Self.me],
            selfEmail: "me@example.com",
            contents: ["ana wants hiring in Q4", "Banana bread for Rui", "Ána said yes", "Fernando owes Ana the deck"]
        )
        #expect(mentioned.map(\.name) == ["Ana", "Rui"])
        #expect(mentioned.map(\.count) == [3, 1])
        #expect(!MeetingBriefService.containsWord("ana", in: "banana"))
        #expect(MeetingBriefService.containsWord("ana", in: "(ana)"))
    }

    @Test
    func `push and why lines`() {
        #expect(MeetingBriefService.pushTitle(eventTitle: "Q4 plan") == "Before Q4 plan")
        #expect(MeetingBriefService.pushTitle(eventTitle: " ") == "Before your meeting")
        #expect(MeetingBriefService.pushBody(count: 3, mentioned: ["Ana", "Rui", "Sam"]) == "3 notes on Ana and Rui")
        #expect(MeetingBriefService.pushBody(count: 1, mentioned: ["Ana"]) == "1 note on Ana")
        #expect(MeetingBriefService.pushBody(count: 2, mentioned: []) == "2 notes for this meeting")
        #expect(MeetingBriefService.why(count: 3, mentioned: [("Ana", 2)]) == "You mentioned Ana in 2 notes")
        #expect(MeetingBriefService.why(count: 1, mentioned: [("Ana", 1)]) == "You mentioned Ana in 1 note")
        #expect(MeetingBriefService.why(count: 3, mentioned: []) == "3 notes match this meeting")
        #expect(MeetingBriefService.why(count: 1, mentioned: []) == "1 note matches this meeting")
        #expect(MeetingBriefService.why(count: 0, mentioned: []) == "Nothing in your notes matches this meeting yet")
    }

    @Test
    func `the floor keeps the nearest five within the distance, one per memory`() {
        func hit(_ id: UUID, _ distance: Float) -> MemorySearchResult {
            MemorySearchResult(id: id, tenantID: UUID(), content: "c", createdAt: nil, distance: distance)
        }
        let ids = (0 ..< 8).map { _ in UUID() }
        let hits = [hit(ids[0], 0.39), hit(ids[1], 0.41), hit(ids[2], 0.1), hit(ids[2], 0.05)]
            + ids[3...].map { hit($0, 0.2) }
        let kept = MeetingBriefService.floor(hits, maxDistance: 0.40)
        #expect(kept.count == 5)
        #expect(kept.first == .init(id: ids[2], similarity: 1 - Double(Float(0.05))))
        #expect(!kept.contains { $0.id == ids[1] })
        #expect(MeetingBriefService.defaultMaxDistance < MemoryController.defaultRelatedMaxDistance)
    }

    @Test
    func `sync attendees are cleaned into the stored shape`() throws {
        #expect(AppleCalendarController.attendeesJSON(nil) == nil)
        let json = try #require(AppleCalendarController.attendeesJSON([
            CalendarAttendeeDTO(name: "  Ana ", email: " "),
            CalendarAttendeeDTO(name: nil, email: nil),
            CalendarAttendeeDTO(email: "rui@example.com"),
        ]))
        #expect(MeetingBriefService.attendees(fromJSON: json) == [CalendarAttendeeDTO(name: "Ana"), CalendarAttendeeDTO(email: "rui@example.com")])
        let many = (0 ..< 150).map { CalendarAttendeeDTO(name: "P\($0)") }
        #expect(MeetingBriefService.attendees(fromJSON: AppleCalendarController.attendeesJSON(many)).count == AppleCalendarController.maxAttendees)
    }
}

// MARK: - Shared fixtures

/// Embeds every text as the unit vector on axis 0 and counts the calls.
private actor AxisEmbedding: EmbeddingService {
    private(set) var calls = 0
    var failing = false

    func setFailing(_ value: Bool) {
        failing = value
    }

    func embed(_: String, tenantID _: UUID) async throws -> [Float] {
        calls += 1
        if failing {
            throw EmbeddingDown()
        }
        var v = [Float](repeating: 0, count: 1536)
        v[0] = 1
        return v
    }

    struct EmbeddingDown: Error {}
}

private enum MeetingFixtures {
    /// A unit vector at cosine `similarity` to axis 0.
    static func vector(similarity: Float, axis: Int = 1) -> [Float] {
        var v = [Float](repeating: 0, count: 1536)
        v[0] = similarity
        v[axis] = (1 - similarity * similarity).squareRoot()
        return v
    }

    @discardableResult
    static func memory(
        _ fluent: Fluent,
        tenantID: UUID,
        _ content: String,
        embedding: [Float],
        reviewState: String = MemoryReviewState.auto
    ) async throws -> UUID {
        try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: embedding,
            reviewState: reviewState,
            kind: .decision
        ).requireID()
    }

    @discardableResult
    static func event(
        _ fluent: Fluent,
        tenantID: UUID,
        title: String,
        startsAt: Date,
        allDay: Bool = false,
        status: String = "confirmed",
        notes: String? = nil,
        attendees: [CalendarAttendeeDTO] = []
    ) async throws -> UUID {
        let sql = try #require(fluent.db() as? any SQLDatabase)
        struct Row: Decodable { let id: UUID }
        let row = try await sql.raw("""
        INSERT INTO calendar_events
            (tenant_id, source, external_id, title, notes, starts_at, ends_at, all_day, status, attendees)
        VALUES
            (\(bind: tenantID), 'apple_eventkit', \(bind: UUID().uuidString), \(bind: title), \(bind: notes),
             \(bind: startsAt), \(bind: startsAt.addingTimeInterval(1800)), \(bind: allDay), \(bind: status),
             \(bind: AppleCalendarController.attendeesJSON(attendees))::jsonb)
        RETURNING id
        """).first(decoding: Row.self)
        return try #require(row).id
    }
}

// MARK: - Scheduler

/// `MeetingBriefScheduler` against Postgres: the 25–35 minute window, the
/// opt-in, one push per event across replicas, no push without a note past
/// the floor, and no part in the one-a-day proactive budget.
///
/// The clock is the `tick(at:)` argument. Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeetingBriefSchedulerTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z")!

    private struct Fixture {
        let push: RecordingPushSender
        let embeddings: AxisEmbedding
        let fluent: Fluent

        func scheduler() -> MeetingBriefScheduler {
            let apns = APNSNotificationService(bundleID: "com.lumina.fernando", fluent: fluent, pushSender: push, logger: Logger(label: "test.meeting.apns"))
            let briefs = MeetingBriefService(
                fluent: fluent,
                embeddings: embeddings,
                search: HybridMemorySearch(memories: MemoryRepository(fluent: fluent), chunks: MemoryChunkRepository(fluent: fluent), logger: Logger(label: "t")),
                maxDistance: MeetingBriefService.defaultMaxDistance
            )
            return MeetingBriefScheduler(fluent: fluent, push: apns, briefs: briefs, logger: Logger(label: "test.meeting"))
        }
    }

    private struct Tenant {
        let id: UUID
        let token: String
        let email: String
    }

    /// A user with a device, opted in unless `enabled` is nil (no prefs row)
    /// or false.
    private static func tenant(_ fluent: Fluent, enabled: Bool? = true, device: Bool = true) async throws -> Tenant {
        let slug = "mb\(UUID().uuidString.prefix(8).lowercased())"
        let email = "\(slug)@test.luminavault"
        let id = try await saveTenant(User(email: email, username: slug, passwordHash: "x"), on: fluent.db())
        let token = "tok-\(UUID().uuidString)"
        if device {
            try await DeviceToken(tenantID: id, token: token, platform: "ios").save(on: fluent.db())
        }
        if let enabled {
            try await ApnsCategoryPrefs(tenantID: id, meetingBriefEnabled: enabled).save(on: fluent.db())
        }
        return Tenant(id: id, token: token, email: email)
    }

    private static func row(_ fluent: Fluent, tenantID: UUID, eventID: UUID) async throws -> (outcome: String, memories: [MeetingBriefService.Match], sent: Bool)? {
        struct Row: Decodable { let outcome: String; let memories: String; let sent_at: Date? }
        let sql = try #require(fluent.db() as? any SQLDatabase)
        guard let row = try await sql.raw("""
        SELECT outcome, memories::text AS memories, sent_at FROM meeting_briefs
        WHERE tenant_id = \(bind: tenantID) AND event_id = \(bind: eventID)
        """).first(decoding: Row.self) else { return nil }
        return try (row.outcome, JSONDecoder().decode([MeetingBriefService.Match].self, from: Data(row.memories.utf8)), row.sent_at != nil)
    }

    /// Migrated first: this suite may run before anything has built the app.
    private static func migrated(_ label: String, _ body: (Fluent) async throws -> Void) async throws {
        try await withTestFluent(label: label) { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await body(fluent)
        }
    }

    private static func fixture(_ fluent: Fluent) -> Fixture {
        Fixture(push: RecordingPushSender(), embeddings: AxisEmbedding(), fluent: fluent)
    }

    private static func sends(_ f: Fixture, to tenant: Tenant) async -> [RecordingPushSender.Send] {
        await f.push.sends.filter { $0.token == tenant.token }
    }

    @Test
    func `only timed, live events starting in 25 to 35 minutes are briefed`() async throws {
        try await Self.migrated("test.meeting.window") { fluent in
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent)
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Q4 plan needs hiring numbers", embedding: MeetingFixtures.vector(similarity: 0.9))
            var ids: [String: UUID] = [:]
            for minutes in [20, 24, 25, 30, 35, 36, 45] {
                ids["m\(minutes)"] = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "m\(minutes)", startsAt: Self.now.addingTimeInterval(Double(minutes) * 60))
            }
            ids["allDay"] = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "allDay", startsAt: Self.now.addingTimeInterval(1800), allDay: true)
            ids["cancelled"] = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "cancelled", startsAt: Self.now.addingTimeInterval(1800), status: "cancelled")

            try await f.scheduler().tick(at: Self.now)

            let titles = await Set(Self.sends(f, to: user).map(\.title))
            #expect(titles == ["Before m25", "Before m30", "Before m35"])
            for skipped in ["m20", "m24", "m36", "m45", "allDay", "cancelled"] {
                #expect(try await Self.row(fluent, tenantID: user.id, eventID: #require(ids[skipped])) == nil, "\(skipped) is not claimed")
            }
        }
    }

    @Test
    func `nobody who has not opted in is briefed`() async throws {
        try await Self.migrated("test.meeting.optin") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(6 * 86400)
            let f = Self.fixture(fluent)
            let noRow = try await Self.tenant(fluent, enabled: nil)
            let off = try await Self.tenant(fluent, enabled: false)
            for user in [noRow, off] {
                try await MeetingFixtures.memory(fluent, tenantID: user.id, "Q4 plan", embedding: MeetingFixtures.vector(similarity: 0.9))
                let event = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "Q4 plan", startsAt: now.addingTimeInterval(1800))
                try await f.scheduler().tick(at: now)
                #expect(await Self.sends(f, to: user).isEmpty)
                #expect(try await Self.row(fluent, tenantID: user.id, eventID: event) == nil)
            }
            #expect(await f.embeddings.calls == 0)
            #expect(try await APNSNotificationService.isCategorySuppressed(.meeting, tenantID: noRow.id, on: fluent.db()))
            #expect(try await APNSNotificationService.isCategorySuppressed(.meeting, tenantID: off.id, on: fluent.db()))
        }
    }

    @Test
    func `the push names attendees from the notes, quietly, and keeps what it counted`() async throws {
        try await Self.migrated("test.meeting.payload") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(7 * 86400)
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent)
            let close = try await MeetingFixtures.memory(fluent, tenantID: user.id, "Ana wants hiring in the Q4 plan", embedding: MeetingFixtures.vector(similarity: 0.95))
            let nearer = try await MeetingFixtures.memory(fluent, tenantID: user.id, "Budget call with Ana and Fernando", embedding: MeetingFixtures.vector(similarity: 0.97, axis: 2))
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Weak link to Rui", embedding: MeetingFixtures.vector(similarity: 0.5))
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Rejected Ana note", embedding: MeetingFixtures.vector(similarity: 0.99), reviewState: MemoryReviewState.rejected)
            let event = try await MeetingFixtures.event(
                fluent,
                tenantID: user.id,
                title: "Q4 plan",
                startsAt: now.addingTimeInterval(1800),
                attendees: [
                    CalendarAttendeeDTO(name: "Fernando", email: user.email.uppercased()),
                    CalendarAttendeeDTO(name: "Ana Silva", email: "ana@example.com"),
                    CalendarAttendeeDTO(name: "Rui", email: "rui@example.com"),
                ]
            )

            let sent = try await f.scheduler().tick(at: now)
            #expect(sent >= 1)
            let send = try #require(await Self.sends(f, to: user).first)
            #expect(send.title == "Before Q4 plan")
            #expect(send.body == "2 notes on Ana", "the user is not an attendee to mention, Rui's note is past the floor")
            #expect(!send.body.contains("hiring"))
            #expect(send.category == .meeting)
            #expect(send.payload["deepLink"] == "luminavault://meeting/\(event.uuidString.lowercased())")
            #expect(send.options == APNSPushOptions(apsCategory: "meeting", interruptionLevel: .passive, threadID: "meeting"))

            let row = try #require(try await Self.row(fluent, tenantID: user.id, eventID: event))
            #expect(row.outcome == "sent")
            #expect(row.sent)
            #expect(row.memories.map(\.id) == [nearer, close])
            #expect(await f.embeddings.calls == 1)
            let hits = try #require(try await Memory.find(close, on: fluent.db())).queryHitCount
            #expect(hits == 0, "a brief is not recall")
        }
    }

    @Test
    func `two replicas ticking together send one push`() async throws {
        try await Self.migrated("test.meeting.claim") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(1 * 86400)
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent)
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Q4 plan", embedding: MeetingFixtures.vector(similarity: 0.9))
            try await MeetingFixtures.event(fluent, tenantID: user.id, title: "Q4 plan", startsAt: now.addingTimeInterval(1800))

            let a = f.scheduler()
            let b = f.scheduler()
            async let first = a.tick(at: now)
            async let second = b.tick(at: now)
            _ = try await (first, second)
            // And a later minute of the same window does not send again.
            try await a.tick(at: now.addingTimeInterval(60))

            #expect(await Self.sends(f, to: user).count == 1)
            #expect(await f.embeddings.calls == 1)
        }
    }

    @Test
    func `nothing past the floor means no push, and the event is not searched again`() async throws {
        try await Self.migrated("test.meeting.empty") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(2 * 86400)
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent)
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Loosely related", embedding: MeetingFixtures.vector(similarity: 0.55))
            let event = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "Q4 plan", startsAt: now.addingTimeInterval(1800))

            try await f.scheduler().tick(at: now)
            try await f.scheduler().tick(at: now.addingTimeInterval(60))

            #expect(await Self.sends(f, to: user).isEmpty)
            let row = try #require(try await Self.row(fluent, tenantID: user.id, eventID: event))
            #expect(row.outcome == "empty")
            #expect(row.memories.isEmpty)
            #expect(!row.sent)
            #expect(await f.embeddings.calls == 1)
        }
    }

    @Test
    func `a spent proactive slot does not block it, and it spends none`() async throws {
        try await Self.migrated("test.meeting.budget") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(3 * 86400)
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent)
            #expect(try await ProactivePushBudget(fluent: fluent).claim(tenantID: user.id, kind: "brief", timezone: "UTC", now: now))
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Q4 plan", embedding: MeetingFixtures.vector(similarity: 0.9))
            try await MeetingFixtures.event(fluent, tenantID: user.id, title: "Q4 plan", startsAt: now.addingTimeInterval(1800))

            try await f.scheduler().tick(at: now)

            #expect(await Self.sends(f, to: user).count == 1)
            struct Row: Decodable { let kind: String }
            let sql = try #require(fluent.db() as? any SQLDatabase)
            let kinds = try await sql.raw("SELECT kind FROM proactive_push_log WHERE tenant_id = \(bind: user.id)").all(decoding: Row.self)
            #expect(kinds.map(\.kind) == ["brief"])
        }
    }

    @Test
    func `no device is recorded before any embedding is paid for`() async throws {
        try await Self.migrated("test.meeting.nodevice") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(4 * 86400)
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent, device: false)
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Q4 plan", embedding: MeetingFixtures.vector(similarity: 0.9))
            let event = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "Q4 plan", startsAt: now.addingTimeInterval(1800))

            try await f.scheduler().tick(at: now)

            #expect(try await Self.row(fluent, tenantID: user.id, eventID: event)?.outcome == "no_device")
            #expect(await f.embeddings.calls == 0)
        }
    }

    @Test
    func `an embedding failure releases the claim for the next tick`() async throws {
        try await Self.migrated("test.meeting.retry") { fluent in
            // Its own day, so no other test's events share the window.
            let now = Self.now.addingTimeInterval(5 * 86400)
            let f = Self.fixture(fluent)
            let user = try await Self.tenant(fluent)
            try await MeetingFixtures.memory(fluent, tenantID: user.id, "Q4 plan", embedding: MeetingFixtures.vector(similarity: 0.9))
            let event = try await MeetingFixtures.event(fluent, tenantID: user.id, title: "Q4 plan", startsAt: now.addingTimeInterval(1800))

            await f.embeddings.setFailing(true)
            try await f.scheduler().tick(at: now)
            #expect(try await Self.row(fluent, tenantID: user.id, eventID: event) == nil)
            #expect(await Self.sends(f, to: user).isEmpty)

            await f.embeddings.setFailing(false)
            try await f.scheduler().tick(at: now.addingTimeInterval(60))
            #expect(await Self.sends(f, to: user).count == 1)
            #expect(try await Self.row(fluent, tenantID: user.id, eventID: event)?.outcome == "sent")
        }
    }
}

// MARK: - HTTP: sync attendees, the preference, the brief endpoint

/// Over the real router, JWT and Postgres, with the deterministic embedder
/// the test config uses (no real key).
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeetingBriefHTTPTests {
    private struct Account {
        let userID: UUID
        let token: String
        let email: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let email = "meeting-\(suffix)@test.luminavault"
        let body = ByteBuffer(
            string: #"{"email":"\#(email)","username":"meeting\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken, email: email)
    }

    private static var wireEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func send(
        _ client: some TestClientProtocol,
        _ method: HTTPRequest.Method,
        _ uri: String,
        token: String,
        body: Data? = nil
    ) async throws -> (HTTPResponse.Status, Data) {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        if body != nil {
            headers[.contentType] = "application/json"
        }
        return try await client.execute(uri: uri, method: method, headers: headers, body: body.map { ByteBuffer(data: $0) }) {
            ($0.status, Data($0.body.readableBytesView))
        }
    }

    private static func storedAttendees(eventExternalID: String, tenantID: UUID) async throws -> CalendarAttendees? {
        try await withTestFluent(label: "test.meeting.attendees.read") { fluent in
            try await CalendarEvent.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$externalID == eventExternalID)
                .first()?
                .attendees
        }
    }

    @Test
    func `attendees ride the sync; absent keeps them, empty clears them`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let consent = try Self.wireEncoder.encode(AppleConsentUpdateRequest(domain: .calendar, allowed: true))
            #expect(try await Self.send(client, .put, "/v1/apple/consent", token: me.token, body: consent).0 == .ok)

            func sync(_ attendees: [CalendarAttendeeDTO]?, title: String = "Q4 plan") async throws {
                let start = Date().addingTimeInterval(3600)
                let input = AppleCalendarEventInput(externalID: "EK-q4", title: title, startsAt: start, endsAt: start.addingTimeInterval(1800), attendees: attendees)
                let body = try Self.wireEncoder.encode(AppleCalendarSyncRequest(events: [input]))
                #expect(try await Self.send(client, .post, "/v1/calendar/sync", token: me.token, body: body).0 == .ok)
            }

            try await sync([CalendarAttendeeDTO(name: "Ana Silva", email: "ana@example.com"), CalendarAttendeeDTO(name: " ", email: nil)])
            var stored = try await Self.storedAttendees(eventExternalID: "EK-q4", tenantID: me.userID)
            #expect(stored?.list.map(\.displayName) == ["Ana Silva"])
            #expect(stored?.list.first?.email == "ana@example.com")

            // An older client: no attendees key at all.
            try await sync(nil, title: "Q4 plan (moved)")
            stored = try await Self.storedAttendees(eventExternalID: "EK-q4", tenantID: me.userID)
            #expect(stored?.list.count == 1)

            try await sync([])
            stored = try await Self.storedAttendees(eventExternalID: "EK-q4", tenantID: me.userID)
            #expect(stored?.list.isEmpty == true)
        }
    }

    @Test
    func `an event synced before attendees existed has none`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let consent = try Self.wireEncoder.encode(AppleConsentUpdateRequest(domain: .calendar, allowed: true))
            _ = try await Self.send(client, .put, "/v1/apple/consent", token: me.token, body: consent)
            let json = #"{"events":[{"externalID":"EK-old","title":"Standup","startsAt":"2026-11-03T10:00:00Z","endsAt":"2026-11-03T10:15:00Z","allDay":false}]}"#
            #expect(try await Self.send(client, .post, "/v1/calendar/sync", token: me.token, body: Data(json.utf8)).0 == .ok)
            #expect(try await Self.storedAttendees(eventExternalID: "EK-old", tenantID: me.userID) == nil)
        }
    }

    @Test
    func `the meeting brief preference is off until turned on`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let (_, initial) = try await Self.send(client, .get, "/v1/me/apns-categories", token: me.token)
            var prefs = try testJSONDecoder().decode(APNSCategoryPrefsResponse.self, from: initial)
            #expect(prefs.meetingBriefEnabled == false)
            #expect(prefs.chatEnabled)

            let (status, updated) = try await Self.send(client, .put, "/v1/me/apns-categories", token: me.token, body: Data(#"{"meetingBriefEnabled":true}"#.utf8))
            #expect(status == .ok)
            prefs = try testJSONDecoder().decode(APNSCategoryPrefsResponse.self, from: updated)
            #expect(prefs.meetingBriefEnabled == true)
            #expect(prefs.nudgeEnabled, "a sparse put leaves the rest alone")

            let (_, reread) = try await Self.send(client, .get, "/v1/me/apns-categories", token: me.token)
            #expect(try testJSONDecoder().decode(APNSCategoryPrefsResponse.self, from: reread).meetingBriefEnabled == true)
            let suppressed = try await withTestFluent(label: "test.meeting.prefs") { fluent in
                try await APNSNotificationService.isCategorySuppressed(.meeting, tenantID: me.userID, on: fluent.db())
            }
            #expect(!suppressed)

            _ = try await Self.send(client, .put, "/v1/me/apns-categories", token: me.token, body: Data(#"{"meetingBriefEnabled":false}"#.utf8))
            let (_, off) = try await Self.send(client, .get, "/v1/me/apns-categories", token: me.token)
            #expect(try testJSONDecoder().decode(APNSCategoryPrefsResponse.self, from: off).meetingBriefEnabled == false)
        }
    }

    @Test
    func `the brief is the caller's own, with the matching notes and a why`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let other = try await Self.register(client: client)
            let attendees = [CalendarAttendeeDTO(name: "Ana Silva", email: "ana@example.com")]
            let start = Date().addingTimeInterval(3 * 86400)

            let (eventID, storedEventID, farMemory) = try await withTestFluent(label: "test.meeting.brief.seed") { fluent in
                let eventID = try await MeetingFixtures.event(fluent, tenantID: me.userID, title: "Q4 plan", startsAt: start, attendees: attendees)
                // The deterministic embedder maps the event's own query text
                // to a fixed vector; a note stored under that vector is a
                // perfect match, one on another axis is far past the floor.
                let event = MeetingBriefService.Event(id: eventID, tenantID: me.userID, title: "Q4 plan", notes: nil, location: nil, startsAt: start, endsAt: start, attendees: attendees)
                let query = MeetingBriefService.queryText(for: event, selfEmail: me.email)
                let exact = try await DeterministicEmbeddingService().embed(query, tenantID: me.userID)
                try await MeetingFixtures.memory(fluent, tenantID: me.userID, "Ana wants hiring in the Q4 plan", embedding: exact)
                try await MeetingFixtures.memory(fluent, tenantID: me.userID, "Rejected: Ana", embedding: exact, reviewState: MemoryReviewState.rejected)
                var axis = [Float](repeating: 0, count: 1536)
                axis[7] = 1
                let far = try await MeetingFixtures.memory(fluent, tenantID: me.userID, "Garden plans", embedding: axis)

                // A second event the scheduler already briefed: the endpoint
                // shows what the push counted, not a fresh match.
                let storedEventID = try await MeetingFixtures.event(fluent, tenantID: me.userID, title: "Garden", startsAt: start)
                let sql = try #require(fluent.db() as? any SQLDatabase)
                try await sql.raw("""
                INSERT INTO meeting_briefs (tenant_id, event_id, outcome, sent_at, memories)
                VALUES (\(bind: me.userID), \(bind: storedEventID), 'sent', NOW(),
                        \(bind: #"[{"id":"\#(far.uuidString)","similarity":0.77}]"#)::jsonb)
                """).run()
                return (eventID, storedEventID, far)
            }

            let (status, data) = try await Self.send(client, .get, "/v1/calendar/events/\(eventID)/brief", token: me.token)
            #expect(status == .ok)
            let brief = try testJSONDecoder().decode(MeetingBriefResponse.self, from: data)
            #expect(brief.event.id == eventID)
            #expect(brief.event.title == "Q4 plan")
            #expect(brief.event.attendees == attendees)
            #expect(brief.memories.map(\.snippet) == ["Ana wants hiring in the Q4 plan"])
            #expect(brief.memories.first?.kind == "decision")
            #expect((brief.memories.first?.similarity ?? 0) > 0.99)
            #expect(brief.why == "You mentioned Ana in 1 note")

            let (storedStatus, storedData) = try await Self.send(client, .get, "/v1/calendar/events/\(storedEventID)/brief", token: me.token)
            #expect(storedStatus == .ok)
            let stored = try testJSONDecoder().decode(MeetingBriefResponse.self, from: storedData)
            #expect(stored.memories.map(\.id) == [farMemory])
            #expect(stored.memories.first?.similarity == 0.77)
            #expect(stored.why == "1 note matches this meeting")

            #expect(try await Self.send(client, .get, "/v1/calendar/events/\(eventID)/brief", token: other.token).0 == .notFound)
            #expect(try await Self.send(client, .get, "/v1/calendar/events/\(UUID())/brief", token: me.token).0 == .notFound)
            #expect(try await Self.send(client, .get, "/v1/calendar/events/not-a-uuid/brief", token: me.token).0 == .badRequest)
        }
    }

    @Test
    func `an event with nothing past the floor has an empty brief, not an error`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let eventID = try await withTestFluent(label: "test.meeting.brief.empty") { fluent in
                var axis = [Float](repeating: 0, count: 1536)
                axis[9] = 1
                try await MeetingFixtures.memory(fluent, tenantID: me.userID, "Unrelated", embedding: axis)
                return try await MeetingFixtures.event(fluent, tenantID: me.userID, title: "Dentist", startsAt: Date().addingTimeInterval(86400))
            }
            let (status, data) = try await Self.send(client, .get, "/v1/calendar/events/\(eventID)/brief", token: me.token)
            #expect(status == .ok)
            let brief = try testJSONDecoder().decode(MeetingBriefResponse.self, from: data)
            #expect(brief.memories.isEmpty)
            #expect(brief.why == "Nothing in your notes matches this meeting yet")
        }
    }
}
