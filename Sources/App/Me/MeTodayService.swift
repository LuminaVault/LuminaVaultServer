import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// HER-206 — assembles the `MeTodayResponse` aggregate from the existing
/// per-domain repositories / services. Pure read; never mutates state.
/// Stays out of the cache plumbing — `MeTodayController` is responsible
/// for `MeTodayCache.get` / `put`, the service just computes a fresh
/// payload when the cache misses.
struct MeTodayService: Sendable {
    let fluent: Fluent
    let memories: MemoryRepository
    let achievements: AchievementsService
    let spaces: SpacesService
    let catalog: AchievementCatalog
    let logger: Logger

    func build(tenantID: UUID, tier: String) async throws -> MeTodayResponse {
        let now = Date()

        let lastMemory: MeTodayLastMemoryDTO? = try await fetchLastMemory(tenantID: tenantID)
        let spaceList = try await spaces.list(tenantID: tenantID)
        let unlockedToday = try await fetchUnlockedToday(tenantID: tenantID, now: now)
        let healthSummary = try await fetchHealthSummary(tenantID: tenantID, now: now)

        return MeTodayResponse(
            // TODO(HER-206-followup): server-generated coaching line.
            // v1 returns nil so the iOS widget shows the placeholder
            // copy; nudge generation needs Hermes inference + a new
            // SoulService snapshot and is a discrete unit of work.
            todayNudge: nil,
            lastMemory: lastMemory,
            openSpacesCount: spaceList.count,
            unlockedAchievementsToday: unlockedToday,
            healthSummary: healthSummary,
            tier: tier,
            // TODO(HER-206-followup): trial_days_remaining needs
            // `users.trial_ends_at` (no such column today). Returning
            // nil now so iOS treats it as "not on trial" without
            // crashing — adopt the field once billing surfaces it.
            trialDaysRemaining: nil,
            generatedAt: now,
        )
    }

    // MARK: - Fragments

    private func fetchLastMemory(tenantID: UUID) async throws -> MeTodayLastMemoryDTO? {
        let rows = try await memories.listPaginated(tenantID: tenantID, tag: nil, limit: 1, offset: 0)
        guard let row = rows.first, let id = row.id, let createdAt = row.createdAt else { return nil }
        return MeTodayLastMemoryDTO(
            id: id,
            // Memory has no `title` column; derive a short preview from
            // `content`. Widget shows a single line so 80 chars is plenty.
            title: Self.titlePreview(from: row.content),
            savedAt: createdAt,
        )
    }

    private func fetchUnlockedToday(tenantID: UUID, now: Date) async throws -> [MeTodayUnlockedAchievementDTO] {
        let unlocks = try await achievements.recentUnlocks(for: tenantID, limit: 20)
        let dayStart = Calendar.current.startOfDay(for: now)
        let byKey = catalog.subsByKey
        return unlocks.compactMap { row -> MeTodayUnlockedAchievementDTO? in
            guard let unlockedAt = row.unlockedAt, unlockedAt >= dayStart else { return nil }
            let label = byKey[row.achievementKey]?.label ?? row.achievementKey
            return MeTodayUnlockedAchievementDTO(
                id: row.achievementKey,
                title: label,
                unlockedAt: unlockedAt,
            )
        }
    }

    private func fetchHealthSummary(tenantID: UUID, now: Date) async throws -> MeTodayHealthSummaryDTO? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        let dayStart = Calendar.current.startOfDay(for: now)
        let stepsRows = try await sql.raw("""
        SELECT COALESCE(SUM(value_numeric), 0)::BIGINT AS total
        FROM health_events
        WHERE tenant_id = \(bind: tenantID)
          AND type = 'steps'
          AND recorded_at >= \(bind: dayStart)
        """).all(decoding: HealthSumRow.self)
        let stepsToday = stepsRows.first.map { Int($0.total) }

        let prevDay = dayStart.addingTimeInterval(-86_400)
        let sleepRows = try await sql.raw("""
        SELECT COALESCE(SUM(value_numeric), 0)::BIGINT AS total
        FROM health_events
        WHERE tenant_id = \(bind: tenantID)
          AND type = 'sleep_minutes'
          AND recorded_at >= \(bind: prevDay)
          AND recorded_at <  \(bind: dayStart)
        """).all(decoding: HealthSumRow.self)
        let sleepMinutes = sleepRows.first.map { Int($0.total) } ?? 0
        let sleepDuration: String? = sleepMinutes > 0 ? Self.iso8601Duration(minutes: sleepMinutes) : nil

        if stepsToday == nil, sleepDuration == nil { return nil }
        return MeTodayHealthSummaryDTO(stepsToday: stepsToday, sleepLastNight: sleepDuration)
    }

    // MARK: - Helpers

    static func titlePreview(from content: String) -> String {
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(77)) + "..."
    }

    static func iso8601Duration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0, mins > 0 { return "PT\(hours)H\(mins)M" }
        if hours > 0 { return "PT\(hours)H" }
        return "PT\(mins)M"
    }
}

private struct HealthSumRow: Decodable {
    let total: Int64
}
