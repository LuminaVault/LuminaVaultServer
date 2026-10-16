import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// `GET /v1/me/resurface` — a few memories worth looking at again today.
/// Deterministic SQL, no model call.
///
/// Three lanes, filled in this order and deduped by memory:
///
/// 1. **due** — the user asked to see it again (`soon` / `later` on
///    `POST /v1/memory/:id/review`) and `next_review_at` has passed. Oldest
///    due first.
/// 2. **onThisDay** — saved exactly a month, six months or a year ago on the
///    user's calendar (`users.timezone`), or on this month/day two or more
///    years ago. Longest ago first.
/// 3. **fading** — a decision or preference nobody has looked at
///    (`COALESCE(last_reviewed_at, created_at)`) for longer than the
///    `review-overdue` age. Oldest first.
///
/// Never shown: rejected memories, muted ones (`never`), model-made memories
/// still waiting for approval, anything reviewed in the last 24 hours, and
/// anything scheduled for later (`next_review_at` still in the future) — the
/// user already said when they want to see it.
struct MeResurfaceService {
    let fluent: Fluent

    static let defaultLimit = 3
    static let maxLimit = 10
    /// A memory reviewed this recently is not offered again.
    static let recentlyReviewedWindow: TimeInterval = 24 * 60 * 60
    static let fadingKinds: [String] = [MemoryKindDTO.decision.rawValue, MemoryKindDTO.preference.rawValue]

    private struct Row: Decodable {
        let id: UUID
        let content: String
        let kind: String?
        let created_at: Date
        let space_id: UUID?
        /// `yyyy-MM-dd` of the lane's reference instant on the user's calendar:
        /// `created_at` for onThisDay, last looked-at for fading.
        let local_day: String?
    }

    func build(user: User, limit: Int, now: Date = Date()) async throws -> ResurfaceResponse {
        let tenantID = try user.requireID()
        let zone = TimeZone(identifier: user.timezone) ?? TimeZone(identifier: "UTC")!
        let timezone = zone.identifier
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for resurface")
        }

        var picked: [ResurfaceItemDTO] = []
        var seen: Set<UUID> = []
        func take(_ items: [ResurfaceItemDTO]) {
            for item in items where picked.count < limit && !seen.contains(item.memoryId) {
                picked.append(item)
                seen.insert(item.memoryId)
            }
        }

        let filter = eligible(tenantID: tenantID, now: now)

        let due = try await sql.raw("""
        SELECT id, content, kind, created_at, space_id, NULL::text AS local_day
        FROM memories
        WHERE \(filter)
          AND next_review_at IS NOT NULL AND next_review_at <= \(bind: now)
        ORDER BY next_review_at ASC, id ASC
        LIMIT \(bind: limit)
        """).all(decoding: Row.self)
        take(due.map { Self.item($0, reason: .due, why: "You asked to see this again") })
        if picked.count >= limit {
            return ResurfaceResponse(items: picked)
        }

        let anniversaries = Self.anniversaries(now: now, zone: zone)
        let today = Self.dayKey(now, zone: zone)
        let monthDay = String(today.dropFirst(5)) // "MM-dd"
        let twoYearsAgo = (Int(today.prefix(4)) ?? 0) - 2
        let onThisDay = try await sql.raw("""
        SELECT id, content, kind, created_at, space_id, local_day::text AS local_day
        FROM (
            SELECT id, content, kind, created_at, space_id,
                   (created_at AT TIME ZONE \(bind: timezone))::date AS local_day
            FROM memories
            WHERE \(filter)
              AND created_at < \(bind: now.addingTimeInterval(-27 * 24 * 60 * 60))
        ) dated
        WHERE local_day::text IN (\(bind: anniversaries.month), \(bind: anniversaries.halfYear), \(bind: anniversaries.year))
           OR (to_char(local_day, 'MM-DD') = \(bind: monthDay)
               AND EXTRACT(YEAR FROM local_day) <= \(bind: twoYearsAgo))
        ORDER BY local_day ASC, id ASC
        LIMIT 50
        """).all(decoding: Row.self)
        take(onThisDay.compactMap { row in
            guard let day = row.local_day,
                  let why = Self.onThisDayWhy(day: day, today: today, anniversaries: anniversaries)
            else { return nil }
            return Self.item(row, reason: .onThisDay, why: why)
        })
        if picked.count >= limit {
            return ResurfaceResponse(items: picked)
        }

        let cutoff = now.addingTimeInterval(-MemoryHealthFilter.reviewOverdueAge)
        let fading = try await sql.raw("""
        SELECT id, content, kind, created_at, space_id,
               (COALESCE(last_reviewed_at, created_at) AT TIME ZONE \(bind: timezone))::date::text AS local_day
        FROM memories
        WHERE \(filter)
          AND kind IN (\(unsafeRaw: MeRecapService.sqlList(Self.fadingKinds)))
          AND COALESCE(last_reviewed_at, created_at) < \(bind: cutoff)
        ORDER BY COALESCE(last_reviewed_at, created_at) ASC, id ASC
        LIMIT \(bind: limit)
        """).all(decoding: Row.self)
        take(fading.map { row in
            Self.item(row, reason: .fading, why: Self.fadingWhy(kind: row.kind, since: row.local_day))
        })
        return ResurfaceResponse(items: picked)
    }

    /// The exclusions every lane shares.
    private func eligible(tenantID: UUID, now: Date) -> SQLQueryString {
        """
        tenant_id = \(bind: tenantID)
          AND review_state <> \(bind: MemoryReviewState.rejected)
          AND NOT resurface_muted
          AND NOT (review_state = \(bind: MemoryReviewState.pending)
                   AND origin_kind IN (\(unsafeRaw: MeRecapService.sqlList(MeRecapService.learnedKinds))))
          AND (last_reviewed_at IS NULL OR last_reviewed_at < \(bind: now.addingTimeInterval(-Self.recentlyReviewedWindow)))
          AND (next_review_at IS NULL OR next_review_at <= \(bind: now))
        """
    }

    private static func item(_ row: Row, reason: ResurfaceReason, why: String) -> ResurfaceItemDTO {
        ResurfaceItemDTO(
            memoryId: row.id,
            snippet: MemoryController.relatedSnippet(row.content),
            kind: row.kind,
            createdAt: row.created_at,
            spaceId: row.space_id,
            reason: reason,
            why: why
        )
    }

    // MARK: - Calendar

    struct Anniversaries: Equatable {
        let month: String
        let halfYear: String
        let year: String
    }

    /// Today minus one month, six months and one year on the user's calendar.
    /// `Calendar` clamps to the end of a shorter month (31 March → 28 Feb).
    static func anniversaries(now: Date, zone: TimeZone) -> Anniversaries {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        func back(_ months: Int) -> String {
            dayKey(calendar.date(byAdding: .month, value: -months, to: today) ?? today, zone: zone)
        }
        return Anniversaries(month: back(1), halfYear: back(6), year: back(12))
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func onThisDayWhy(day: String, today: String, anniversaries: Anniversaries) -> String? {
        switch day {
        case anniversaries.year: return "Saved a year ago today"
        case anniversaries.halfYear: return "Saved 6 months ago today"
        case anniversaries.month: return "Saved a month ago today"
        default:
            guard let year = Int(day.prefix(4)), let thisYear = Int(today.prefix(4)),
                  day.dropFirst(5) == today.dropFirst(5), thisYear - year >= 2
            else { return nil }
            return "Saved \(thisYear - year) years ago today"
        }
    }

    static func fadingWhy(kind: String?, since day: String?) -> String {
        let noun = kind == MemoryKindDTO.preference.rawValue ? "A preference" : "A decision"
        guard let day, let since = monthYear(day) else {
            return "\(noun) you haven't revisited in a while"
        }
        return "\(noun) you haven't revisited since \(since)"
    }

    /// `2026-03-14` → `March 2026`.
    static func monthYear(_ day: String) -> String? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), (1 ... 12).contains(month) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return "\(calendar.standaloneMonthSymbols[month - 1]) \(year)"
    }
}
