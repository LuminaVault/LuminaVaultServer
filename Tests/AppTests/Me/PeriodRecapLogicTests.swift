@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// The year / month recap's rules without a database: the local calendar,
/// the card maths, the themes cache policy, and the one model call (through a
/// stub transport — never a real key).
struct PeriodRecapLogicTests {
    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func window(
        _ kind: RecapPeriodKind,
        _ year: Int,
        _ month: Int? = nil,
        tz: String = "UTC",
        now: String
    ) -> PeriodRecapWindow {
        PeriodRecapWindow(kind: kind, year: year, month: month, timezone: tz, now: date(now))!
    }

    // MARK: - Window

    @Test
    func `a running year is clamped to today and compared with the same stretch last year`() {
        let w = Self.window(.year, 2026, now: "2026-10-16T12:00:00Z")
        #expect(w.start == Self.date("2026-01-01T00:00:00Z"))
        #expect(w.end == Self.date("2026-10-17T00:00:00Z"))
        #expect(w.previousStart == Self.date("2025-01-01T00:00:00Z"))
        #expect(w.previousEnd == Self.date("2025-10-17T00:00:00Z"))
        #expect(!w.isComplete)
        #expect(!w.isFuture)
        #expect(w.days.count == 289)
        #expect(w.startKey == "2026-01-01")
        #expect(w.endKey == "2026-10-16")
        #expect(w.bucketKeys == (1 ... 10).map { String(format: "2026-%02d", $0) })
        #expect(w.periodKey == "2026")
    }

    @Test
    func `a finished month covers every day and compares with the whole previous month`() {
        let w = Self.window(.month, 2026, 2, now: "2026-10-16T12:00:00Z")
        #expect(w.isComplete)
        #expect(w.days.count == 28)
        #expect(w.bucketKeys.first == "2026-02-01")
        #expect(w.bucketKeys.last == "2026-02-28")
        #expect(w.previousStart == Self.date("2026-01-01T00:00:00Z"))
        #expect(w.previousEnd == Self.date("2026-02-01T00:00:00Z"))
        #expect(w.periodKey == "2026-02")
    }

    @Test
    func `days are local and survive a DST change`() {
        // Lisbon leaves summer time on 25 October 2026.
        let w = Self.window(.month, 2026, 10, tz: "Europe/Lisbon", now: "2026-11-02T12:00:00Z")
        #expect(w.days.count == 31)
        #expect(w.start == Self.date("2026-09-30T23:00:00Z"))
        #expect(w.end == Self.date("2026-11-01T00:00:00Z"))
        #expect(Set(w.days.map(\.key)).count == 31)
    }

    @Test
    func `weekdays are ISO, Monday first`() {
        let w = Self.window(.month, 2026, 6, now: "2026-10-16T12:00:00Z")
        // 1 June 2026 is a Monday, 7 June a Sunday.
        #expect(w.days[0].weekday == 1)
        #expect(w.days[6].weekday == 7)
    }

    @Test
    func `an unknown timezone falls back to UTC and bad periods are refused`() {
        let w = Self.window(.year, 2026, tz: "Mars/Olympus", now: "2026-10-16T12:00:00Z")
        #expect(w.timezone == "UTC")
        #expect(PeriodRecapWindow(kind: .month, year: 2026, month: 13, timezone: "UTC", now: Date()) == nil)
        #expect(PeriodRecapWindow(kind: .month, year: 2026, month: nil, timezone: "UTC", now: Date()) == nil)
        #expect(PeriodRecapWindow(kind: .year, year: 2026, month: 1, timezone: "UTC", now: Date()) == nil)
        #expect(PeriodRecapWindow(kind: .year, year: 1999, month: nil, timezone: "UTC", now: Date()) == nil)
    }

    @Test
    func `a future period has no days`() {
        let w = Self.window(.year, 2027, now: "2026-10-16T12:00:00Z")
        #expect(w.isFuture)
        #expect(w.days.isEmpty)
        #expect(w.start == w.end)
    }

    // MARK: - Builder

    private typealias Counts = PeriodRecapBuilder.DayCounts

    private static func activeMonth() -> (PeriodRecapWindow, PeriodRecapBuilder.Inputs) {
        let w = window(.month, 2026, 3, now: "2026-10-16T12:00:00Z")
        var inputs = PeriodRecapBuilder.Inputs()
        // Two runs: 2–4 (three days) and 10–12 (three days, the later one wins).
        for day in [2, 3, 4, 10, 11, 12] {
            inputs.days[String(format: "2026-03-%02d", day)] = Counts(captures: 2, learned: 1, asked: 1)
        }
        inputs.days["2026-03-20"] = Counts(captures: 9)
        return (w, inputs)
    }

    @Test
    func `the series fills empty buckets and the busiest bucket is found`() {
        let (w, inputs) = Self.activeMonth()
        let series = PeriodRecapBuilder.series(window: w, days: inputs.days)
        #expect(series.count == 31)
        #expect(series[0] == RecapBucketDTO(key: "2026-03-01", count: 0))
        #expect(series[1] == RecapBucketDTO(key: "2026-03-02", count: 3))
        let peak = PeriodRecapBuilder.peak(window: w, days: inputs.days, series: series)
        #expect(peak?.busiest == RecapBucketDTO(key: "2026-03-20", count: 9))
        // 20 March 2026 is a Friday.
        #expect(peak?.busiestWeekday == 5)
        #expect(peak?.weekdayCounts.reduce(0, +) == 6 * 4 + 9)
    }

    @Test
    func `a year series buckets by month`() {
        let w = Self.window(.year, 2026, now: "2026-03-10T12:00:00Z")
        let series = PeriodRecapBuilder.series(window: w, days: [
            "2026-01-05": Counts(captures: 1),
            "2026-01-20": Counts(learned: 2),
            "2026-03-01": Counts(captures: 4, asked: 5),
        ])
        #expect(series == [
            RecapBucketDTO(key: "2026-01", count: 3),
            RecapBucketDTO(key: "2026-02", count: 0),
            RecapBucketDTO(key: "2026-03", count: 4),
        ])
    }

    @Test
    func `the longest streak is inside the period and the latest tie wins`() {
        let (w, inputs) = Self.activeMonth()
        let streak = PeriodRecapBuilder.streak(window: w, days: inputs.days)
        #expect(streak.longestDays == 3)
        #expect(streak.longestStart == "2026-03-10")
        #expect(streak.longestEnd == "2026-03-12")
        #expect(streak.activeDays == 7)
        #expect(streak.totalDays == 31)
    }

    @Test
    func `no activity means no streak`() {
        let w = Self.window(.month, 2026, 3, now: "2026-10-16T12:00:00Z")
        let streak = PeriodRecapBuilder.streak(window: w, days: [:])
        #expect(streak == RecapStreakCardDTO(longestDays: 0, longestStart: nil, longestEnd: nil, activeDays: 0, totalDays: 31))
    }

    @Test
    func `persona is the busiest band per hour, and balanced below ten events`() {
        var hours = Array(repeating: 0, count: 24)
        hours[23] = 6
        hours[1] = 4
        hours[12] = 9
        #expect(PeriodRecapBuilder.persona(hourCounts: hours) == .nightOwl)
        hours[12] = 30
        #expect(PeriodRecapBuilder.persona(hourCounts: hours) == .daytime)
        var few = Array(repeating: 0, count: 24)
        few[6] = 9
        #expect(PeriodRecapBuilder.persona(hourCounts: few) == .balanced)
        #expect(PeriodRecapBuilder.rhythm(hourCounts: few) == nil)
        few[7] = 1
        #expect(PeriodRecapBuilder.rhythm(hourCounts: few)?.persona == .earlyBird)
        #expect(PeriodRecapBuilder.rhythm(hourCounts: few)?.peakHour == 6)
    }

    @Test
    func `eligibility explains why there is no recap`() {
        let future = Self.window(.year, 2027, now: "2026-10-16T12:00:00Z")
        #expect(PeriodRecapBuilder.unavailableReason(window: future, accountCreatedAt: nil, inputs: .init()) == .periodInFuture)

        let old = Self.window(.year, 2024, now: "2026-10-16T12:00:00Z")
        #expect(PeriodRecapBuilder.unavailableReason(
            window: old,
            accountCreatedAt: Self.date("2026-01-03T00:00:00Z"),
            inputs: .init()
        ) == .beforeAccount)

        let (month, inputs) = Self.activeMonth()
        #expect(PeriodRecapBuilder.unavailableReason(window: month, accountCreatedAt: nil, inputs: inputs) == nil)
        var thin = PeriodRecapBuilder.Inputs()
        thin.days["2026-03-02"] = Counts(captures: 9)
        thin.days["2026-03-03"] = Counts(captures: 9)
        #expect(PeriodRecapBuilder.unavailableReason(window: month, accountCreatedAt: nil, inputs: thin) == .notEnoughActivity)

        // A year needs activity in two months.
        let year = Self.window(.year, 2026, now: "2026-10-16T12:00:00Z")
        var oneMonth = PeriodRecapBuilder.Inputs()
        oneMonth.days["2026-03-02"] = Counts(captures: 30)
        #expect(PeriodRecapBuilder.unavailableReason(window: year, accountCreatedAt: nil, inputs: oneMonth) == .notEnoughActivity)
        oneMonth.days["2026-04-02"] = Counts(captures: 1)
        #expect(PeriodRecapBuilder.unavailableReason(window: year, accountCreatedAt: nil, inputs: oneMonth) == nil)
    }

    @Test
    func `the deck only holds cards with something to say`() {
        let (w, inputs) = Self.activeMonth()
        let themes = RecapThemesCardDTO(status: .pending, fallbackSentence: "x")
        let recap = PeriodRecapBuilder.build(window: w, accountCreatedAt: nil, inputs: inputs, themes: themes, now: Date())
        #expect(recap.available)
        #expect(recap.order == [.intro, .captures, .peak, .chats, .streak, .themes, .summary])
        #expect(recap.captures?.captures == 21)
        #expect(recap.captures?.learned == 6)
        #expect(recap.chats?.messagesSent == 6)
        #expect(recap.rhythm == nil)
        #expect(recap.topics == nil)

        var richer = inputs
        richer.topTags = [RecapCountDTO(label: "swift", count: 3)]
        richer.skillRuns = 2
        richer.achievements = [RecapAchievementDTO(key: "k", title: "K", unlockedAt: Date())]
        richer.hourCounts[9] = 12
        let full = PeriodRecapBuilder.build(window: w, accountCreatedAt: nil, inputs: richer, themes: nil, now: Date())
        #expect(full.order == [.intro, .captures, .peak, .rhythm, .topics, .chats, .skills, .streak, .achievements, .summary])
    }

    @Test
    func `an unavailable recap carries no cards`() {
        let w = Self.window(.month, 2026, 3, now: "2026-10-16T12:00:00Z")
        let recap = PeriodRecapBuilder.build(window: w, accountCreatedAt: nil, inputs: .init(), themes: nil, now: Date())
        #expect(!recap.available)
        #expect(recap.unavailableReason == .notEnoughActivity)
        #expect(recap.order.isEmpty)
        #expect(recap.captures == nil)
    }

    @Test
    func `share text is numbers only and says so far while running`() {
        let running = Self.window(.year, 2026, now: "2026-10-16T12:00:00Z")
        #expect(PeriodRecapBuilder.shareText(window: running, memories: 160, asked: 1, longestStreak: 12)
            == "My 2026 so far on LuminaVault: 160 memories, 1 question asked, a 12-day streak.")
        let done = Self.window(.month, 2026, 3, now: "2026-10-16T12:00:00Z")
        #expect(PeriodRecapBuilder.shareText(window: done, memories: 1, asked: 0, longestStreak: 1)
            == "My March 2026 on LuminaVault: 1 memory.")
    }

    @Test
    func `the fallback sentence is built from tags or counts`() {
        let year = Self.window(.year, 2026, now: "2026-10-16T12:00:00Z")
        let tags = ["swift", "running", "coffee", "extra"].map { RecapCountDTO(label: $0, count: 1) }
        #expect(PeriodRecapBuilder.fallbackSentence(window: year, topTags: tags, memories: 9)
            == "A year of swift, running and coffee.")
        #expect(PeriodRecapBuilder.fallbackSentence(window: year, topTags: Array(tags.prefix(1)), memories: 9)
            == "A year of swift.")
        let month = Self.window(.month, 2026, 3, now: "2026-10-16T12:00:00Z")
        #expect(PeriodRecapBuilder.fallbackSentence(window: month, topTags: [], memories: 9)
            == "A month of 9 memories, all in one place.")
    }

    // MARK: - Themes policy

    private static func row(
        _ status: String,
        attempts: Int = 1,
        requested: Date? = nil,
        generated: Date? = nil
    ) -> PeriodRecapThemesRow {
        PeriodRecapThemesRow(
            status: status,
            headline: status == "ready" ? "H" : nil,
            sentence: status == "ready" ? "S" : nil,
            themes: [],
            attempts: attempts,
            requested_at: requested,
            generated_at: generated
        )
    }

    @Test
    func `themes are generated once, retried with limits, and refreshed daily while running`() {
        let now = Self.date("2026-10-16T12:00:00Z")
        let policy = PeriodRecapThemesPolicy.self
        #expect(policy.needsGeneration(row: nil, isComplete: true, now: now))
        // In flight.
        #expect(!policy.needsGeneration(row: Self.row("pending", requested: now.addingTimeInterval(-30)), isComplete: true, now: now))
        // Pending but abandoned.
        #expect(policy.needsGeneration(row: Self.row("pending", requested: now.addingTimeInterval(-600)), isComplete: true, now: now))
        #expect(!policy.needsGeneration(
            row: Self.row("pending", attempts: 3, requested: now.addingTimeInterval(-600)),
            isComplete: true,
            now: now
        ))
        // Ready: never again for a finished period, daily for a running one.
        let fresh = Self.row("ready", generated: now.addingTimeInterval(-3600))
        let stale = Self.row("ready", generated: now.addingTimeInterval(-90000))
        #expect(!policy.needsGeneration(row: stale, isComplete: true, now: now))
        #expect(!policy.needsGeneration(row: fresh, isComplete: false, now: now))
        #expect(policy.needsGeneration(row: stale, isComplete: false, now: now))
        // Fallback: hourly while attempts remain, then daily.
        #expect(!policy.needsGeneration(row: Self.row("fallback", generated: now.addingTimeInterval(-60)), isComplete: true, now: now))
        #expect(policy.needsGeneration(row: Self.row("fallback", generated: now.addingTimeInterval(-4000)), isComplete: true, now: now))
        #expect(!policy.needsGeneration(
            row: Self.row("fallback", attempts: 3, generated: now.addingTimeInterval(-4000)),
            isComplete: true,
            now: now
        ))
    }

    @Test
    func `the themes card always has something to show`() {
        let now = Date()
        let policy = PeriodRecapThemesPolicy.self
        #expect(policy.card(row: nil, claimed: false, enabled: false, fallback: "f", now: now).status == .disabled)
        #expect(policy.card(row: nil, claimed: true, enabled: true, fallback: "f", now: now).status == .pending)
        #expect(policy.card(row: nil, claimed: false, enabled: true, fallback: "f", now: now).status == .fallback)
        let ready = policy.card(row: Self.row("ready"), claimed: true, enabled: true, fallback: "f", now: now)
        #expect(ready.status == .ready)
        #expect(ready.headline == "H")
        #expect(ready.fallbackSentence == "f")
        let inFlight = Self.row("pending", requested: now.addingTimeInterval(-5))
        #expect(policy.card(row: inFlight, claimed: false, enabled: true, fallback: "f", now: now).status == .pending)
    }

    // MARK: - Generator

    private static let input = PeriodRecapThemesInput(
        periodName: "2026",
        kind: .year,
        memories: 160,
        asked: 80,
        topTags: [RecapCountDTO(label: "swift", count: 30)],
        topSpace: "Work",
        persona: .nightOwl,
        busiest: "2026-03",
        snippets: ["Ship on Tuesdays"]
    )

    @Test
    func `the payload sends no sampling knobs and ends on the user's turn`() throws {
        let data = try PeriodRecapThemesGenerator.payload(model: "m", input: Self.input)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        #expect(json["max_tokens"] as? Int == 400)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.last?["role"] as? String == "user")
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("swift (30)"))
        #expect(user.contains("Ship on Tuesdays"))
    }

    @Test
    func `a good reply is trimmed and capped`() throws {
        let long = String(repeating: "a", count: 300)
        let reply = try Self.completion(#"{"headline":"  Night owl coder  ","sentence":"\#(long)","themes":["swift","running","coffee","extra"]}"#)
        let written = try #require(PeriodRecapThemesGenerator.parse(response: reply))
        #expect(written.headline == "Night owl coder")
        #expect(written.sentence.count == 200)
        #expect(written.themes == ["swift", "running", "coffee"])
    }

    @Test
    func `a malformed or empty reply is nil`() throws {
        #expect(try PeriodRecapThemesGenerator.parse(response: Self.completion("not json")) == nil)
        #expect(try PeriodRecapThemesGenerator.parse(response: Self.completion(#"{"headline":"","sentence":"s"}"#)) == nil)
        #expect(PeriodRecapThemesGenerator.parse(response: Data("{}".utf8)) == nil)
    }

    @Test
    func `the generator writes, and returns nil on an error or a timeout`() async {
        let good = StubRecapTransport(reply: .content(#"{"headline":"H","sentence":"S","themes":[]}"#))
        let written = await Self.generator(good).write(sessionKey: "k", input: Self.input)
        #expect(written == .init(headline: "H", sentence: "S", themes: []))
        #expect(await good.calls == 1)

        let failing = StubRecapTransport(reply: .error)
        #expect(await Self.generator(failing).write(sessionKey: "k", input: Self.input) == nil)

        var slow = Self.generator(StubRecapTransport(reply: .hang))
        slow.timeoutSeconds = 0.2
        #expect(await slow.write(sessionKey: "k", input: Self.input) == nil)
    }

    private static func generator(_ transport: StubRecapTransport) -> PeriodRecapThemesGenerator {
        PeriodRecapThemesGenerator(transport: transport, model: "test-model", logger: Logger(label: "test.recap.themes"))
    }

    static func completion(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ])
    }

    // MARK: - Controller

    @Test
    func `params default to the current local year and month`() throws {
        // 31 Dec 23:30 in Los Angeles is already 1 Jan in UTC.
        let now = Self.date("2027-01-01T07:30:00Z")
        let tz = "America/Los_Angeles"
        #expect(try PeriodRecapController.parse(period: nil, year: nil, month: nil, timezone: tz, now: now)
            == .init(kind: .year, year: 2026, month: nil))
        #expect(try PeriodRecapController.parse(period: "month", year: nil, month: nil, timezone: tz, now: now)
            == .init(kind: .month, year: 2026, month: 12))
        #expect(try PeriodRecapController.parse(period: "month", year: "2025", month: "3", timezone: tz, now: now)
            == .init(kind: .month, year: 2025, month: 3))
    }

    @Test
    func `bad params are refused`() {
        let now = Date()
        #expect(throws: (any Error).self) { try PeriodRecapController.parse(period: "week", year: nil, month: nil, timezone: "UTC", now: now) }
        #expect(throws: (any Error).self) { try PeriodRecapController.parse(period: "year", year: "26", month: nil, timezone: "UTC", now: now) }
        #expect(throws: (any Error).self) { try PeriodRecapController.parse(period: "year", year: nil, month: "3", timezone: "UTC", now: now) }
        #expect(throws: (any Error).self) { try PeriodRecapController.parse(period: "month", year: nil, month: "0", timezone: "UTC", now: now) }
    }

    @Test
    func `a pending themes card is never cached`() {
        func recap(complete: Bool, status: RecapThemesStatus?) -> PeriodRecapResponse {
            PeriodRecapResponse(
                period: .year,
                year: 2026,
                month: nil,
                start: "",
                end: "",
                timezone: "UTC",
                isComplete: complete,
                available: true,
                themes: status.map { RecapThemesCardDTO(status: $0, fallbackSentence: "f") },
                shareText: "",
                generatedAt: Date()
            )
        }
        #expect(PeriodRecapController.cacheControl(for: recap(complete: true, status: .pending)) == "private, no-cache")
        #expect(PeriodRecapController.cacheControl(for: recap(complete: true, status: .ready)) == "private, max-age=3600")
        #expect(PeriodRecapController.cacheControl(for: recap(complete: false, status: nil)) == "private, max-age=300")
    }
}

/// Canned chat completions for the themes call. Never a real key.
actor StubRecapTransport: HermesChatTransport {
    enum Reply {
        case content(String)
        case error
        case hang
    }

    private let reply: Reply
    private(set) var calls = 0
    private(set) var lastPayload: Data?

    init(reply: Reply) {
        self.reply = reply
    }

    nonisolated func chatCompletions(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        try await answer(payload)
    }

    private func answer(_ payload: Data) async throws -> Data {
        calls += 1
        lastPayload = payload
        switch reply {
        case let .content(text):
            return try PeriodRecapLogicTests.completion(text)
        case .error:
            throw StubRecapError.upstream
        case .hang:
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
    }
}

enum StubRecapError: Error {
    case upstream
}
