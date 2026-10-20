@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// "What I learned this week" push: Sunday 18:00–18:59 on the user's clock,
/// once a week, only when there is something to say, only with the day's
/// proactive budget, and never past the digest opt-out.
///
/// The clock is the `tick(at:)` argument. Sunday 2026-10-18 closes the week
/// that started Monday 2026-10-12. Zones are deliberately unusual
/// (Kathmandu +05:45, St John's −02:30 in October) so the base database's own
/// users rarely share the hour; assertions only look at this suite's users.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct LearnedDigestSchedulerTests {
    private static let kathmandu = "Asia/Kathmandu"
    private static let stJohns = "America/St_Johns"
    /// Sunday 18:30 in Kathmandu.
    private static let sundayKathmandu = iso("2026-10-18T12:45:00Z")
    /// Sunday 18:30 in St John's (NDT, −02:30).
    private static let sundayStJohns = iso("2026-10-18T21:00:00Z")

    private static func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private struct Fixture {
        let scheduler: LearnedDigestScheduler
        let push: RecordingPushSender
    }

    private static func fixture(_ fluent: Fluent) -> Fixture {
        let push = RecordingPushSender()
        let service = APNSNotificationService(bundleID: "com.lumina.fernando", fluent: fluent, pushSender: push, logger: Logger(label: "test.learned.apns"))
        return Fixture(scheduler: LearnedDigestScheduler(fluent: fluent, push: service, logger: Logger(label: "test.learned")), push: push)
    }

    /// A user with one device and, unless `learned` is false, two preferences
    /// and one decision saved during the week before `now`.
    private static func user(
        fluent: Fluent,
        timezone: String,
        learned: Bool = true,
        before now: Date
    ) async throws -> (id: UUID, token: String) {
        let slug = "ld\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        user.timezone = timezone
        try await user.save(on: fluent.db())
        try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
        let id = try user.requireID()
        let token = "tok-\(UUID().uuidString)"
        try await DeviceToken(tenantID: id, token: token, platform: "ios").save(on: fluent.db())
        if learned {
            try await MeLearnedTests.memory(fluent: fluent, tenantID: id, content: "Likes window seats", createdAt: now.addingTimeInterval(-86400), kind: .preference)
            try await MeLearnedTests.memory(fluent: fluent, tenantID: id, content: "Tea after 3pm", createdAt: now.addingTimeInterval(-2 * 86400), kind: .preference)
            try await MeLearnedTests.memory(fluent: fluent, tenantID: id, content: "Booked the October trip", createdAt: now.addingTimeInterval(-3 * 86400), kind: .decision)
        }
        return (id, token)
    }

    private static func outcome(_ fluent: Fluent, tenantID: UUID, weekStart: String = "2026-10-12") async throws -> String? {
        struct Row: Decodable { let outcome: String }
        let sql = try #require(fluent.db() as? any SQLDatabase)
        return try await sql.raw("""
        SELECT outcome FROM learned_digest_log WHERE tenant_id = \(bind: tenantID) AND week_start = \(bind: weekStart)::date
        """).first(decoding: Row.self)?.outcome
    }

    private static func budgetKind(_ fluent: Fluent, tenantID: UUID, day: String = "2026-10-18") async throws -> String? {
        struct Row: Decodable { let kind: String }
        let sql = try #require(fluent.db() as? any SQLDatabase)
        return try await sql.raw("""
        SELECT kind FROM proactive_push_log WHERE tenant_id = \(bind: tenantID) AND day = \(bind: day)::date
        """).first(decoding: Row.self)?.kind
    }

    // MARK: - Timing

    @Test
    func `only users whose own clock reads Sunday 18 are sent`() async throws {
        try await withTestFluent(label: "test.learned.timing") { fluent in
            let f = Self.fixture(fluent)
            let nepal = try await Self.user(fluent: fluent, timezone: Self.kathmandu, before: Self.sundayKathmandu)
            let newfoundland = try await Self.user(fluent: fluent, timezone: Self.stJohns, before: Self.sundayKathmandu)
            func tokens() async -> Set<String> {
                await Set(f.push.sends.map(\.token))
            }

            // 17:59 Sunday and 18:30 Saturday in Kathmandu: nobody.
            try await f.scheduler.tick(at: Self.iso("2026-10-18T12:14:00Z"))
            try await f.scheduler.tick(at: Self.iso("2026-10-17T12:45:00Z"))
            #expect(await tokens().isDisjoint(with: [nepal.token, newfoundland.token]))

            try await f.scheduler.tick(at: Self.sundayKathmandu)
            #expect(await tokens().contains(nepal.token))
            #expect(await !tokens().contains(newfoundland.token))
            #expect(try await Self.outcome(fluent, tenantID: nepal.id) == "sent")
            #expect(try await Self.budgetKind(fluent, tenantID: nepal.id) == "learned")

            try await f.scheduler.tick(at: Self.sundayStJohns)
            #expect(await tokens().contains(newfoundland.token))
            // 19:00 Sunday is past the hour.
            #expect(LearnedDigestScheduler.weekStartIfSendHour(now: Self.iso("2026-10-18T13:15:00Z"), timezone: Self.kathmandu) == nil)
        }
    }

    @Test
    func `the push carries counts only, quietly, to the learned screen`() async throws {
        try await withTestFluent(label: "test.learned.payload") { fluent in
            let f = Self.fixture(fluent)
            let user = try await Self.user(fluent: fluent, timezone: Self.kathmandu, before: Self.sundayKathmandu)
            try await MeLearnedTests.soulChange(fluent: fluent, tenantID: user.id, title: "Morning person", createdAt: Self.sundayKathmandu.addingTimeInterval(-3600))
            try await f.scheduler.tick(at: Self.sundayKathmandu)

            let send = try #require(await f.push.sends.first(where: { $0.token == user.token }))
            #expect(send.title == "What I learned this week")
            #expect(send.subtitle == nil)
            // One soul change + two preferences, one decision.
            #expect(send.body == "3 things about you and 1 decision — keep, edit or forget them.")
            #expect(!send.body.contains("window"))
            #expect(send.category == .digest)
            #expect(send.payload["deepLink"] == "luminavault://learned")
            #expect(send.options == APNSPushOptions(apsCategory: "learned", interruptionLevel: .passive, threadID: "learned"))
        }
    }

    // MARK: - Once a week

    @Test
    func `a week is sent once, the next week again`() async throws {
        try await withTestFluent(label: "test.learned.weekly") { fluent in
            let f = Self.fixture(fluent)
            let user = try await Self.user(fluent: fluent, timezone: Self.kathmandu, before: Self.sundayKathmandu)
            func count() async -> Int {
                await f.push.sends.count(where: { $0.token == user.token })
            }

            try await f.scheduler.tick(at: Self.sundayKathmandu)
            try await f.scheduler.tick(at: Self.sundayKathmandu.addingTimeInterval(60))
            try await f.scheduler.tick(at: Self.sundayKathmandu.addingTimeInterval(14 * 60))
            #expect(await count() == 1)

            // Two schedulers (replicas) on the same minute: still one.
            let other = Self.fixture(fluent)
            try await other.scheduler.tick(at: Self.sundayKathmandu.addingTimeInterval(120))
            #expect(await other.push.sends.isEmpty(where: { $0.token == user.token }))

            let nextSunday = Self.sundayKathmandu.addingTimeInterval(7 * 86400)
            try await MeLearnedTests.memory(fluent: fluent, tenantID: user.id, content: "Switched to oat milk", createdAt: nextSunday.addingTimeInterval(-86400), kind: .decision)
            try await f.scheduler.tick(at: nextSunday)
            #expect(await count() == 2)
            #expect(try await Self.outcome(fluent, tenantID: user.id, weekStart: "2026-10-19") == "sent")
        }
    }

    @Test
    func `an empty week sends nothing and is not retried`() async throws {
        try await withTestFluent(label: "test.learned.empty") { fluent in
            let f = Self.fixture(fluent)
            let user = try await Self.user(fluent: fluent, timezone: Self.kathmandu, learned: false, before: Self.sundayKathmandu)
            // Only things outside the digest: a fact, an approved preference, an old decision.
            try await MeLearnedTests.memory(fluent: fluent, tenantID: user.id, content: "A fact", createdAt: Self.sundayKathmandu.addingTimeInterval(-3600), kind: .fact)
            try await MeLearnedTests.memory(fluent: fluent, tenantID: user.id, content: "Kept", createdAt: Self.sundayKathmandu.addingTimeInterval(-3600), kind: .preference, reviewState: MemoryReviewState.approved)
            try await MeLearnedTests.memory(fluent: fluent, tenantID: user.id, content: "Old", createdAt: Self.sundayKathmandu.addingTimeInterval(-9 * 86400), kind: .decision)

            try await f.scheduler.tick(at: Self.sundayKathmandu)
            #expect(await f.push.sends.isEmpty(where: { $0.token == user.token }))
            #expect(try await Self.outcome(fluent, tenantID: user.id) == "empty")
            #expect(try await Self.budgetKind(fluent, tenantID: user.id) == nil)

            // Something learned later in the hour waits for the app.
            try await MeLearnedTests.memory(fluent: fluent, tenantID: user.id, content: "Late", createdAt: Self.sundayKathmandu, kind: .decision)
            try await f.scheduler.tick(at: Self.sundayKathmandu.addingTimeInterval(600))
            #expect(await f.push.sends.isEmpty(where: { $0.token == user.token }))
        }
    }

    // MARK: - Gates

    @Test
    func `a spent proactive budget skips the week`() async throws {
        try await withTestFluent(label: "test.learned.budget") { fluent in
            let f = Self.fixture(fluent)
            let user = try await Self.user(fluent: fluent, timezone: Self.kathmandu, before: Self.sundayKathmandu)
            let spent = try await ProactivePushBudget(fluent: fluent).claim(
                tenantID: user.id, kind: "daily_brief", timezone: Self.kathmandu, now: Self.sundayKathmandu.addingTimeInterval(-6 * 3600)
            )
            #expect(spent)

            try await f.scheduler.tick(at: Self.sundayKathmandu)
            #expect(await f.push.sends.isEmpty(where: { $0.token == user.token }))
            #expect(try await Self.outcome(fluent, tenantID: user.id) == "budget_spent")
            #expect(try await Self.budgetKind(fluent, tenantID: user.id) == "daily_brief")
        }
    }

    @Test
    func `the digest opt-out suppresses it and leaves the budget alone`() async throws {
        try await withTestFluent(label: "test.learned.optout") { fluent in
            let f = Self.fixture(fluent)
            let user = try await Self.user(fluent: fluent, timezone: Self.kathmandu, before: Self.sundayKathmandu)
            try await ApnsCategoryPrefs(tenantID: user.id, digestEnabled: false).save(on: fluent.db())

            try await f.scheduler.tick(at: Self.sundayKathmandu)
            #expect(await f.push.sends.isEmpty(where: { $0.token == user.token }))
            #expect(try await Self.outcome(fluent, tenantID: user.id) == "opted_out")
            #expect(try await Self.budgetKind(fluent, tenantID: user.id) == nil)
        }
    }

    // MARK: - Placeholder jobs

    /// M145 switches off the jobs the legacy migrator made from the two
    /// placeholder skills, but only copies nobody edited.
    @Test
    func `M145 turns off untouched placeholder jobs only`() async throws {
        try await withTestFluent(label: "test.learned.m145") { fluent in
            let (tenantID, _) = try await Self.user(fluent: fluent, timezone: "UTC", learned: false, before: Date())
            func job(_ skill: String, versions: Int) async throws -> UUID {
                let definition = WorkflowDefinitionDTO(
                    trigger: .schedule,
                    triggerConfiguration: ["cron": "0 18 * * 0", "timezone": "UTC"],
                    nodes: [],
                    edges: []
                )
                let workflow = Workflow(tenantID: tenantID, name: "Job · \(skill) v\(versions)", descriptionText: nil, definition: definition, isLegacyJob: true, legacySkillName: skill)
                try await workflow.create(on: fluent.db())
                for number in 1 ... versions {
                    let version = WorkflowVersion()
                    version.id = UUID()
                    version.tenantID = tenantID
                    version.workflowID = try workflow.requireID()
                    version.version = number
                    version.definition = definition
                    try await version.create(on: fluent.db())
                    workflow.publishedVersionID = version.id
                }
                try await workflow.save(on: fluent.db())
                return try workflow.requireID()
            }
            let memo = try await job("weekly-memo", versions: 1)
            let health = try await job("health-correlate", versions: 1)
            let edited = try await job("weekly-memo", versions: 2)
            let brief = try await job("daily-brief", versions: 1)

            try await M145_CreateLearnedDigestLog().prepare(on: fluent.db())

            func enabled(_ id: UUID) async throws -> Bool {
                try #require(try await Workflow.find(id, on: fluent.db())).enabled
            }
            #expect(try await !enabled(memo))
            #expect(try await !enabled(health))
            #expect(try await enabled(edited))
            #expect(try await enabled(brief))
        }
    }

    // MARK: - Pure

    @Test
    func `week start is the local Monday of the Sunday`() {
        #expect(LearnedDigestScheduler.weekStartIfSendHour(now: Self.sundayKathmandu, timezone: Self.kathmandu) == "2026-10-12")
        // 18:30 Sunday in Los Angeles is already Monday in UTC.
        #expect(LearnedDigestScheduler.weekStartIfSendHour(now: Self.iso("2026-10-19T01:30:00Z"), timezone: "America/Los_Angeles") == "2026-10-12")
        #expect(LearnedDigestScheduler.weekStartIfSendHour(now: Self.iso("2026-10-19T01:30:00Z"), timezone: "UTC") == nil)
        // Unknown zones count as UTC.
        #expect(LearnedDigestScheduler.weekStartIfSendHour(now: Self.iso("2026-10-18T18:05:00Z"), timezone: "Not/AZone") == "2026-10-12")
    }

    @Test
    func `push copy counts and pluralises`() {
        func digest(soul: Int, preferences: Int, decisions: Int) -> LearnedDigestResponse {
            let now = Date()
            func memory(_ kind: String) -> LearnedMemoryDTO {
                LearnedMemoryDTO(id: UUID(), snippet: "s", kind: kind, reviewState: "auto", createdAt: now)
            }
            return LearnedDigestResponse(
                since: now, until: now,
                soulChanges: (0 ..< soul).map { _ in LearnedSoulChangeDTO(id: UUID(), title: "t", summary: "s", createdAt: now) },
                memories: (0 ..< preferences).map { _ in memory("preference") } + (0 ..< decisions).map { _ in memory("decision") }
            )
        }
        #expect(MeLearnedService.pushBody(for: digest(soul: 0, preferences: 2, decisions: 3)) == "2 things about you and 3 decisions — keep, edit or forget them.")
        #expect(MeLearnedService.pushBody(for: digest(soul: 1, preferences: 0, decisions: 0)) == "1 thing about you — keep, edit or forget it.")
        #expect(MeLearnedService.pushBody(for: digest(soul: 0, preferences: 0, decisions: 1)) == "1 decision — keep, edit or forget it.")
        #expect(MeLearnedService.pushBody(for: digest(soul: 0, preferences: 0, decisions: 0)) == nil)
    }
}

private extension Array {
    func isEmpty(where predicate: (Element) -> Bool) -> Bool {
        !contains(where: predicate)
    }
}
