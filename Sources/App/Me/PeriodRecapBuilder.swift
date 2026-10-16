import Foundation
import LuminaVaultShared

/// Turns the raw counts `PeriodRecapService` reads into the card deck. Pure,
/// so every rule here (buckets, peak, streak, persona, eligibility, order,
/// share text) is tested without a database.
enum PeriodRecapBuilder {
    /// One local day's counts, the same split as `MeRecapService`.
    struct DayCounts: Equatable {
        var captures = 0
        var learned = 0
        var asked = 0

        var memories: Int {
            captures + learned
        }

        var isActive: Bool {
            captures + learned + asked > 0
        }
    }

    struct Inputs {
        var days: [String: DayCounts] = [:]
        var previous = DayCounts()
        var hourCounts: [Int] = Array(repeating: 0, count: 24)
        var kinds: [RecapCountDTO] = []
        var topTags: [RecapCountDTO] = []
        var topSpace: RecapCountDTO?
        var conversations = 0
        var skillRuns = 0
        var topSkill: RecapCountDTO?
        var achievements: [RecapAchievementDTO] = []
        var firstCapture: RecapFirstCaptureDTO?
    }

    // MARK: - Eligibility

    static let minMonthActivity = 5
    static let minMonthActiveDays = 3
    static let minYearActivity = 20
    static let minYearActiveMonths = 2

    static func unavailableReason(
        window: PeriodRecapWindow,
        accountCreatedAt: Date?,
        inputs: Inputs
    ) -> RecapUnavailableReason? {
        if window.isFuture {
            return .periodInFuture
        }
        if let accountCreatedAt, window.periodEnd <= accountCreatedAt {
            return .beforeAccount
        }
        let activeDayKeys = window.days.map(\.key).filter { inputs.days[$0]?.isActive == true }
        let activity = window.days.reduce(0) { total, day in
            let counts = inputs.days[day.key] ?? DayCounts()
            return total + counts.memories + counts.asked
        }
        switch window.kind {
        case .month:
            if activity < minMonthActivity || activeDayKeys.count < minMonthActiveDays {
                return .notEnoughActivity
            }
        case .year:
            let activeMonths = Set(activeDayKeys.map { $0.prefix(7) }).count
            if activity < minYearActivity || activeMonths < minYearActiveMonths {
                return .notEnoughActivity
            }
        }
        return nil
    }

    // MARK: - Cards

    static func series(window: PeriodRecapWindow, days: [String: DayCounts]) -> [RecapBucketDTO] {
        var byBucket: [String: Int] = [:]
        for day in window.days {
            let bucket = window.kind == .year ? String(day.key.prefix(7)) : day.key
            byBucket[bucket, default: 0] += days[day.key]?.memories ?? 0
        }
        return window.bucketKeys.map { RecapBucketDTO(key: $0, count: byBucket[$0] ?? 0) }
    }

    /// Busiest bucket (latest wins a tie) and Monday-first weekday counts of
    /// memories plus messages sent.
    static func peak(window: PeriodRecapWindow, days: [String: DayCounts], series: [RecapBucketDTO]) -> RecapPeakCardDTO? {
        guard series.reduce(0, { $0 + $1.count }) > 0,
              let busiest = series.enumerated().max(by: { lhs, rhs in
                  lhs.element.count == rhs.element.count ? lhs.offset < rhs.offset : lhs.element.count < rhs.element.count
              })?.element
        else { return nil }
        var weekdays = Array(repeating: 0, count: 7)
        for day in window.days {
            let counts = days[day.key] ?? DayCounts()
            weekdays[day.weekday - 1] += counts.memories + counts.asked
        }
        let best = weekdays.enumerated().max { $0.element < $1.element }?.offset ?? 0
        return RecapPeakCardDTO(busiest: busiest, weekdayCounts: weekdays, busiestWeekday: best + 1)
    }

    static func streak(window: PeriodRecapWindow, days: [String: DayCounts]) -> RecapStreakCardDTO {
        var best: (length: Int, start: String?, end: String?) = (0, nil, nil)
        var run = 0
        var runStart: String?
        var active = 0
        for day in window.days {
            guard days[day.key]?.isActive == true else {
                run = 0
                continue
            }
            active += 1
            if run == 0 {
                runStart = day.key
            }
            run += 1
            // `>=` so the latest of two equal runs wins.
            if run >= best.length {
                best = (run, runStart, day.key)
            }
        }
        return RecapStreakCardDTO(
            longestDays: best.length,
            longestStart: best.start,
            longestEnd: best.end,
            activeDays: active,
            totalDays: window.days.count
        )
    }

    static let minRhythmEvents = 10

    /// The band with the most activity per hour. Normalised by width, or the
    /// seven-hour day band would win for almost everyone.
    static func persona(hourCounts: [Int]) -> RecapPersona {
        guard hourCounts.count == 24, hourCounts.reduce(0, +) >= minRhythmEvents else { return .balanced }
        let bands: [(RecapPersona, [Int])] = [
            (.earlyBird, Array(5 ... 9)),
            (.daytime, Array(10 ... 16)),
            (.evening, Array(17 ... 21)),
            (.nightOwl, [22, 23, 0, 1, 2, 3, 4]),
        ]
        let scored = bands.map { persona, hours in
            (persona, Double(hours.reduce(0) { $0 + hourCounts[$1] }) / Double(hours.count))
        }
        return scored.max { $0.1 < $1.1 }?.0 ?? .balanced
    }

    static func rhythm(hourCounts: [Int]) -> RecapRhythmCardDTO? {
        guard hourCounts.count == 24, hourCounts.reduce(0, +) >= minRhythmEvents else { return nil }
        let peakHour = hourCounts.enumerated().max { $0.element < $1.element }?.offset ?? 0
        return RecapRhythmCardDTO(hourCounts: hourCounts, peakHour: peakHour, persona: persona(hourCounts: hourCounts))
    }

    // MARK: - Words

    static func periodName(_ window: PeriodRecapWindow) -> String {
        guard let month = window.month else { return String(window.year) }
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        return "\(names.standaloneMonthSymbols[month - 1]) \(window.year)"
    }

    /// Numbers only — never memory content, tags or names, so it is safe to
    /// paste anywhere.
    static func shareText(window: PeriodRecapWindow, memories: Int, asked: Int, longestStreak: Int) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String {
            "\(n) \(n == 1 ? one : many)"
        }
        var parts = [plural(memories, "memory", "memories")]
        if asked > 0 {
            parts.append(plural(asked, "question asked", "questions asked"))
        }
        if longestStreak > 1 {
            parts.append("a \(longestStreak)-day streak")
        }
        let soFar = window.isComplete ? "" : " so far"
        return "My \(periodName(window))\(soFar) on LuminaVault: \(parts.joined(separator: ", "))."
    }

    /// The themes card's sentence when the model has not written one.
    static func fallbackSentence(window: PeriodRecapWindow, topTags: [RecapCountDTO], memories: Int) -> String {
        let span = window.kind == .year ? "A year" : "A month"
        let tags = topTags.prefix(3).map(\.label)
        switch tags.count {
        case 0:
            return "\(span) of \(memories) \(memories == 1 ? "memory" : "memories"), all in one place."
        case 1:
            return "\(span) of \(tags[0])."
        default:
            return "\(span) of \(tags.dropLast().joined(separator: ", ")) and \(tags[tags.count - 1])."
        }
    }

    // MARK: - Deck

    static func build(
        window: PeriodRecapWindow,
        accountCreatedAt: Date?,
        inputs: Inputs,
        themes: RecapThemesCardDTO?,
        now: Date
    ) -> PeriodRecapResponse {
        let current = window.days.reduce(into: DayCounts()) { total, day in
            let counts = inputs.days[day.key] ?? DayCounts()
            total.captures += counts.captures
            total.learned += counts.learned
            total.asked += counts.asked
        }
        let streakCard = streak(window: window, days: inputs.days)
        let share = shareText(
            window: window,
            memories: current.memories,
            asked: current.asked,
            longestStreak: streakCard.longestDays
        )

        if let reason = unavailableReason(window: window, accountCreatedAt: accountCreatedAt, inputs: inputs) {
            return PeriodRecapResponse(
                period: window.kind,
                year: window.year,
                month: window.month,
                start: window.startKey,
                end: window.endKey,
                timezone: window.timezone,
                isComplete: window.isComplete,
                available: false,
                unavailableReason: reason,
                shareText: share,
                generatedAt: now
            )
        }

        let seriesBuckets = series(window: window, days: inputs.days)
        let captures = RecapCapturesCardDTO(
            captures: current.captures,
            learned: current.learned,
            previousCaptures: inputs.previous.captures,
            previousLearned: inputs.previous.learned,
            series: seriesBuckets,
            byKind: inputs.kinds,
            firstCapture: inputs.firstCapture
        )
        let peakCard = peak(window: window, days: inputs.days, series: seriesBuckets)
        let rhythmCard = rhythm(hourCounts: inputs.hourCounts)
        let topics = inputs.topTags.isEmpty && inputs.topSpace == nil
            ? nil
            : RecapTopicsCardDTO(topTags: inputs.topTags, topSpace: inputs.topSpace)
        let chats = current.asked + inputs.conversations > 0
            ? RecapChatsCardDTO(
                conversations: inputs.conversations,
                messagesSent: current.asked,
                previousMessagesSent: inputs.previous.asked
            )
            : nil
        let skills = inputs.skillRuns > 0 ? RecapSkillsCardDTO(runs: inputs.skillRuns, topSkill: inputs.topSkill) : nil
        let achievements = inputs.achievements.isEmpty
            ? nil
            : RecapAchievementsCardDTO(
                unlocked: inputs.achievements.count,
                items: Array(inputs.achievements.prefix(5))
            )

        let optional: [(RecapCardKind, Bool)] = [
            (.peak, peakCard != nil),
            (.rhythm, rhythmCard != nil),
            (.topics, topics != nil),
            (.chats, chats != nil),
            (.skills, skills != nil),
            (.streak, true),
            (.achievements, achievements != nil),
            (.themes, themes != nil),
        ]
        let order: [RecapCardKind] = [.intro, .captures] + optional.filter(\.1).map(\.0) + [.summary]

        return PeriodRecapResponse(
            period: window.kind,
            year: window.year,
            month: window.month,
            start: window.startKey,
            end: window.endKey,
            timezone: window.timezone,
            isComplete: window.isComplete,
            available: true,
            order: order,
            captures: captures,
            peak: peakCard,
            rhythm: rhythmCard,
            topics: topics,
            chats: chats,
            skills: skills,
            streak: streakCard,
            achievements: achievements,
            themes: themes,
            shareText: share,
            generatedAt: now
        )
    }
}
