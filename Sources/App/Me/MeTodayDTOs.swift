import Foundation
import Hummingbird

// HER-213: MeToday* types pruned from LuminaVaultShared v0.11.0 per the
// wire-types-only boundary (they aggregate server-derived metrics:
// trial-days, generatedAt timestamp, achievement state, etc.). Live
// server-side now.

struct MeTodayLastMemoryDTO: Codable, Sendable {
    let id: UUID
    let title: String
    let savedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, title
        case savedAt = "saved_at"
    }
    init(id: UUID, title: String, savedAt: Date) {
        self.id = id; self.title = title; self.savedAt = savedAt
    }
}

struct MeTodayUnlockedAchievementDTO: Codable, Sendable {
    let id: String
    let title: String
    let unlockedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, title
        case unlockedAt = "unlocked_at"
    }
    init(id: String, title: String, unlockedAt: Date) {
        self.id = id; self.title = title; self.unlockedAt = unlockedAt
    }
}

struct MeTodayHealthSummaryDTO: Codable, Sendable {
    let stepsToday: Int?
    /// ISO-8601 duration (e.g. "PT7H12M") so iOS can hand it to
    /// `ISO8601DurationFormatter` without server-side calendar math.
    let sleepLastNight: String?
    enum CodingKeys: String, CodingKey {
        case stepsToday = "steps_today"
        case sleepLastNight = "sleep_last_night"
    }
    init(stepsToday: Int?, sleepLastNight: String?) {
        self.stepsToday = stepsToday; self.sleepLastNight = sleepLastNight
    }
}

struct MeTodayResponse: Codable, Sendable {
    let todayNudge: String?
    let lastMemory: MeTodayLastMemoryDTO?
    let openSpacesCount: Int
    let unlockedAchievementsToday: [MeTodayUnlockedAchievementDTO]
    let healthSummary: MeTodayHealthSummaryDTO?
    let tier: String
    let trialDaysRemaining: Int?
    let generatedAt: Date
    enum CodingKeys: String, CodingKey {
        case todayNudge = "today_nudge"
        case lastMemory = "last_memory"
        case openSpacesCount = "open_spaces_count"
        case unlockedAchievementsToday = "unlocked_achievements_today"
        case healthSummary = "health_summary"
        case tier
        case trialDaysRemaining = "trial_days_remaining"
        case generatedAt = "generated_at"
    }
    init(
        todayNudge: String?,
        lastMemory: MeTodayLastMemoryDTO?,
        openSpacesCount: Int,
        unlockedAchievementsToday: [MeTodayUnlockedAchievementDTO],
        healthSummary: MeTodayHealthSummaryDTO?,
        tier: String,
        trialDaysRemaining: Int?,
        generatedAt: Date
    ) {
        self.todayNudge = todayNudge
        self.lastMemory = lastMemory
        self.openSpacesCount = openSpacesCount
        self.unlockedAchievementsToday = unlockedAchievementsToday
        self.healthSummary = healthSummary
        self.tier = tier
        self.trialDaysRemaining = trialDaysRemaining
        self.generatedAt = generatedAt
    }
}

extension MeTodayResponse: ResponseEncodable {}
