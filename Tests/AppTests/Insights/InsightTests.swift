@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// HER-37 Slice D — Postgres-backed persistence + worker behaviour
/// tests. Follows the existing `withTestFluent` + `registerMigrations`
/// pattern so M46 is exercised against a real local Postgres.
@Suite(.serialized)
struct InsightTests {
    // MARK: - Persistence

    @Test
    func `Insight save + retrieve round trips`() async throws {
        try await withTestFluent(label: "lv.test.insight.crud") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let row = Insight(
                tenantID: tenantID,
                section: .patterns,
                headline: "You run on Mondays",
                summary: "Of 4 runs this month, 3 were Mondays.",
                sourceMemoryIDs: [UUID(), UUID()],
            )
            try await row.save(on: fluent.db())

            let fetched = try #require(
                await Insight.query(on: fluent.db(), tenantID: tenantID).first(),
            )
            #expect(fetched.headline == "You run on Mondays")
            #expect(fetched.section == "patterns")
            #expect(fetched.sourceMemoryIDs.count == 2)
            #expect(fetched.dismissedAt == nil)
        }
    }

    @Test
    func `Insight stores period boundaries for synthesis rows`() async throws {
        try await withTestFluent(label: "lv.test.insight.period") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(7 * 24 * 3600)
            let row = Insight(
                tenantID: tenantID,
                section: .thisWeek,
                headline: "Your week, in two lines",
                summary: "Lots of writing.",
                periodStart: start,
                periodEnd: end,
            )
            try await row.save(on: fluent.db())

            let dto = try row.toDTO()
            #expect(dto.section == .thisWeek)
            #expect(dto.periodStart == start)
            #expect(dto.periodEnd == end)
        }
    }

    @Test
    func `Insight query is tenant scoped`() async throws {
        try await withTestFluent(label: "lv.test.insight.tenant") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let a = try await Self.makeTenant(on: fluent)
            let b = try await Self.makeTenant(on: fluent)
            try await Insight(tenantID: a, section: .patterns, headline: "A", summary: "a").save(on: fluent.db())
            try await Insight(tenantID: b, section: .patterns, headline: "B", summary: "b").save(on: fluent.db())

            let rowsA = try await Insight.query(on: fluent.db(), tenantID: a).all()
            #expect(rowsA.count == 1)
            #expect(rowsA[0].headline == "A")
        }
    }

    // MARK: - Window math (no DB)

    @Test
    func `weeklyWindow ends at start-of-day and spans 7 days`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = SynthesisWorker.weeklyWindow(endingAt: now)
        #expect(window.end <= now)
        let delta = window.end.timeIntervalSince(window.start)
        #expect(delta == 7 * 24 * 3600)
    }

    @Test
    func `hourComponent and weekdayComponent read in UTC`() {
        // 1970-01-04 02:00:00 UTC — first Sunday after the epoch.
        // 3 days + 2h = 3*86400 + 7200 = 266400.
        let date = Date(timeIntervalSince1970: 266_400)
        #expect(SynthesisWorker.hourComponent(of: date) == 2)
        #expect(SynthesisWorker.weekdayComponent(of: date) == 1)
    }

    // MARK: - Parsing

    @Test
    func `parseSynthesis extracts headline and summary`() throws {
        let envelope = """
        {"choices":[{"message":{"content":"{\\"headline\\": \\"H\\", \\"summary\\": \\"S\\"}"}}]}
        """
        let data = try #require(envelope.data(using: .utf8))
        let parsed = try #require(SynthesisWorker.parseSynthesis(response: data))
        #expect(parsed.headline == "H")
        #expect(parsed.summary == "S")
    }

    @Test
    func `parseSynthesis returns nil on missing fields`() throws {
        let envelope = """
        {"choices":[{"message":{"content":"{\\"headline\\": \\"\\", \\"summary\\": \\"S\\"}"}}]}
        """
        let data = try #require(envelope.data(using: .utf8))
        #expect(SynthesisWorker.parseSynthesis(response: data) == nil)
    }

    @Test
    func `parsePatterns drops empty entries and trims whitespace`() throws {
        let envelope = """
        {"choices":[{"message":{"content":"{\\"patterns\\": [{\\"headline\\": \\"  A  \\", \\"summary\\": \\"a\\"}, {\\"headline\\": \\"\\", \\"summary\\": \\"x\\"}, {\\"headline\\": \\"B\\", \\"summary\\": \\"\\"}]}"}}]}
        """
        let data = try #require(envelope.data(using: .utf8))
        let parsed = try #require(SynthesisWorker.parsePatterns(response: data))
        #expect(parsed.count == 1)
        #expect(parsed[0].headline == "A")
    }

    // MARK: - Worker idempotency (DB-backed)

    @Test
    func `runWeeklyJob is a no-op when row already exists for the period`() async throws {
        try await withTestFluent(label: "lv.test.synth.weekly.idem") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            try await Self.makeMemory(on: fluent, tenantID: tenantID, content: "ran 5k")

            let transport = StubSynthTransport(plainContent: """
            {"headline": "Week 21", "summary": "Lots of running."}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth"),
            )

            let now = Date()
            let window = SynthesisWorker.weeklyWindow(endingAt: now)
            let first = try await worker.runWeeklyJob(tenantID: tenantID, profileUsername: "u", window: window)
            #expect(first == true)
            let again = try await worker.runWeeklyJob(tenantID: tenantID, profileUsername: "u", window: window)
            #expect(again == false)
            let calls = await transport.callCount
            #expect(calls == 1)
        }
    }

    @Test
    func `runPatternJob skips when recent pattern row exists`() async throws {
        try await withTestFluent(label: "lv.test.synth.pattern.cooldown") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            for _ in 0 ..< 5 {
                try await Self.makeMemory(on: fluent, tenantID: tenantID, content: "memo")
            }
            try await Insight(
                tenantID: tenantID,
                section: .patterns,
                headline: "recent",
                summary: "still fresh",
            ).save(on: fluent.db())

            let transport = StubSynthTransport(plainContent: """
            {"patterns": [{"headline": "X", "summary": "x"}]}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth"),
            )

            let inserted = try await worker.runPatternJob(tenantID: tenantID, profileUsername: "u", now: Date())
            #expect(inserted == 0)
            let calls = await transport.callCount
            #expect(calls == 0)
        }
    }

    @Test
    func `runPatternJob inserts up to maxPatternsPerRun`() async throws {
        try await withTestFluent(label: "lv.test.synth.pattern.cap") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            for _ in 0 ..< 5 {
                try await Self.makeMemory(on: fluent, tenantID: tenantID, content: "memo")
            }

            let transport = StubSynthTransport(plainContent: """
            {"patterns": [{"headline": "A", "summary": "a"}, {"headline": "B", "summary": "b"}, {"headline": "C", "summary": "c"}, {"headline": "D", "summary": "d"}, {"headline": "E", "summary": "e"}]}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth"),
                maxPatternsPerRun: 2,
            )

            let inserted = try await worker.runPatternJob(tenantID: tenantID, profileUsername: "u", now: Date())
            #expect(inserted == 2)
            let count = try await Insight.query(on: fluent.db(), tenantID: tenantID).count()
            #expect(count == 2)
        }
    }

    @Test
    func `runWeeklyJob returns false when no memories exist`() async throws {
        try await withTestFluent(label: "lv.test.synth.weekly.empty") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let transport = StubSynthTransport(plainContent: """
            {"headline": "x", "summary": "y"}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth"),
            )
            let result = try await worker.runWeeklyJob(
                tenantID: tenantID,
                profileUsername: "u",
                window: SynthesisWorker.weeklyWindow(endingAt: Date()),
            )
            #expect(result == false)
        }
    }

    // MARK: - Fixtures

    private static func makeTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "ins-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault",
            username: "ins-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub",
        )
        try await user.save(on: fluent.db())
        return id
    }

    private static func makeMemory(on fluent: Fluent, tenantID: UUID, content: String) async throws {
        let mem = Memory(tenantID: tenantID, content: content)
        try await mem.save(on: fluent.db())
    }
}

// MARK: - Test transport

/// Minimal stub for `HermesChatTransport`. Returns a canned chat
/// completion containing the given assistant content, or throws.
/// Tracks call count so cooldown tests can assert no upstream call
/// was made.
private actor StubSynthTransport: HermesChatTransport {
    private let response: Result<String, Error>
    private(set) var callCount: Int = 0

    init(plainContent: String) {
        response = .success(plainContent)
    }

    init(error: Error) {
        response = .failure(error)
    }

    nonisolated func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
        try await record()
    }

    private func record() throws -> Data {
        callCount += 1
        switch response {
        case let .failure(e): throw e
        case let .success(content):
            let body: [String: Any] = [
                "id": "test",
                "model": "test",
                "choices": [[
                    "index": 0,
                    "finish_reason": "stop",
                    "message": ["role": "assistant", "content": content],
                ]],
            ]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
    }
}
