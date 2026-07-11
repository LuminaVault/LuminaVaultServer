@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// HER-37 Slice D — Postgres-backed persistence + worker behaviour
/// tests. Follows the existing `withTestFluent` + `registerMigrations`
/// pattern so M46 is exercised against a real local Postgres.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
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
                sourceMemoryIDs: [UUID(), UUID()]
            )
            try await row.save(on: fluent.db())

            let fetched = try #require(
                await Insight.query(on: fluent.db(), tenantID: tenantID).first()
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
                periodEnd: end
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

    @Test
    func `parseContradictions drops empty entries and trims whitespace`() throws {
        let envelope = """
        {"choices":[{"message":{"content":"{\\"contradictions\\": [{\\"headline\\": \\"  A  \\", \\"summary\\": \\"a\\"}, {\\"headline\\": \\"\\", \\"summary\\": \\"x\\"}, {\\"headline\\": \\"B\\", \\"summary\\": \\"\\"}]}"}}]}
        """
        let data = try #require(envelope.data(using: .utf8))
        let parsed = try #require(SynthesisWorker.parseContradictions(response: data))
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
                logger: Logger(label: "test.synth")
            )

            let now = Date()
            let window = SynthesisWorker.weeklyWindow(endingAt: now)
            let first = try await worker.runWeeklyJob(tenantID: tenantID, sessionKey: "u", window: window)
            #expect(first == true)
            let again = try await worker.runWeeklyJob(tenantID: tenantID, sessionKey: "u", window: window)
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
                summary: "still fresh"
            ).save(on: fluent.db())

            let transport = StubSynthTransport(plainContent: """
            {"patterns": [{"headline": "X", "summary": "x"}]}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth")
            )

            let inserted = try await worker.runPatternJob(tenantID: tenantID, sessionKey: "u", now: Date())
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
                maxPatternsPerRun: 2
            )

            let inserted = try await worker.runPatternJob(tenantID: tenantID, sessionKey: "u", now: Date())
            #expect(inserted == 2)
            let count = try await Insight.query(on: fluent.db(), tenantID: tenantID).count()
            #expect(count == 2)
        }
    }

    @Test
    func `runContradictionJob skips when recent contradiction row exists`() async throws {
        try await withTestFluent(label: "lv.test.synth.contradiction.cooldown") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            for _ in 0 ..< 5 {
                try await Self.makeMemory(on: fluent, tenantID: tenantID, content: "memo")
            }
            try await Insight(
                tenantID: tenantID,
                section: .contradictions,
                headline: "recent",
                summary: "still fresh"
            ).save(on: fluent.db())

            let transport = StubSynthTransport(plainContent: """
            {"contradictions": [{"headline": "X", "summary": "x"}]}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth")
            )

            let inserted = try await worker.runContradictionJob(tenantID: tenantID, sessionKey: "u", now: Date())
            #expect(inserted == 0)
            let calls = await transport.callCount
            #expect(calls == 0)
        }
    }

    @Test
    func `runContradictionJob inserts contradiction rows up to the cap`() async throws {
        try await withTestFluent(label: "lv.test.synth.contradiction.cap") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            var memoryIDs: [UUID] = []
            for index in 0 ..< 5 {
                try await memoryIDs.append(Self.makeMemory(on: fluent, tenantID: tenantID, content: "memo \(index)"))
            }
            let sql = try #require(fluent.db() as? any SQLDatabase)
            for index in 0 ..< 3 {
                let left = UUID(), right = UUID(), edge = UUID()
                try await sql.raw("""
                INSERT INTO knowledge_nodes (id, tenant_id, kind, canonical_key, label, confidence)
                VALUES
                  (\(bind: left), \(bind: tenantID), 'claim', \(bind: "left-\(index)"), \(bind: "Position \(index)"), 1),
                  (\(bind: right), \(bind: tenantID), 'claim', \(bind: "right-\(index)"), \(bind: "Not position \(index)"), 1)
                """).run()
                try await sql.raw("""
                INSERT INTO knowledge_edges (
                    id, tenant_id, from_node_id, to_node_id, predicate, state,
                    confidence, rationale, evidence_fingerprint
                ) VALUES (
                    \(bind: edge), \(bind: tenantID), \(bind: left), \(bind: right),
                    'contradicts', 'suggested', \(bind: 0.9 - Double(index) * 0.1),
                    \(bind: "Exact conflict \(index)"), \(bind: "conflict-\(index)")
                )
                """).run()
                try await sql.raw("""
                INSERT INTO knowledge_evidence (id, tenant_id, edge_id, memory_id, quote)
                VALUES (\(bind: UUID()), \(bind: tenantID), \(bind: edge), \(bind: memoryIDs[index]), \(bind: "evidence \(index)"))
                """).run()
            }

            let transport = StubSynthTransport(plainContent: """
            {"contradictions": [{"headline": "A", "summary": "a"}, {"headline": "B", "summary": "b"}, {"headline": "C", "summary": "c"}]}
            """)
            let worker = SynthesisWorker(
                fluent: fluent,
                memories: MemoryRepository(fluent: fluent),
                transport: transport,
                defaultModel: "test-model",
                logger: Logger(label: "test.synth"),
                maxPatternsPerRun: 2
            )

            let inserted = try await worker.runContradictionJob(tenantID: tenantID, sessionKey: "u", now: Date())
            #expect(inserted == 2)
            let rows = try await Insight.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$section == InsightSection.contradictions.rawValue)
                .all()
            #expect(rows.count == 2)
            #expect(Set(rows.flatMap(\.sourceMemoryIDs)).isSubset(of: Set(memoryIDs)))
            #expect(rows.allSatisfy { $0.sourceMemoryIDs.count == 1 })
            #expect(rows.allSatisfy { $0.knowledgeEdgeID != nil })
            let calls = await transport.callCount
            #expect(calls == 0)
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
                logger: Logger(label: "test.synth")
            )
            let result = try await worker.runWeeklyJob(
                tenantID: tenantID,
                sessionKey: "u",
                window: SynthesisWorker.weeklyWindow(endingAt: Date())
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
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        return id
    }

    @discardableResult
    private static func makeMemory(on fluent: Fluent, tenantID: UUID, content: String) async throws -> UUID {
        let mem = Memory(tenantID: tenantID, content: content)
        try await mem.save(on: fluent.db())
        return try mem.requireID()
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

    nonisolated func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
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
