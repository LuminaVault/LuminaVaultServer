import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// Wave 4 — the daily brief as a short list of cards with an end.
///
/// Runs after the `daily-brief` skill (`SkillRunner.dispatchOutputs`) and
/// stores one brief per tenant per local day in `briefs` (M147). The cards
/// are deterministic except the skill's own sections, which reuse the text
/// the skill already wrote — no extra model call.
///
/// Cards, in this order, each skipped when empty:
/// 1. **today** — the day's calendar events (the same synced cache and
///    consent gate as the skill's `calendar_query` tool).
/// 2. **openLoops** — up to 3 open commitments, due first then oldest. A
///    commitment rides in at most 3 briefs (`surfaced_count`), then lives
///    only in the list.
/// 3. **toRevisit** — one memory from the resurfacing picker.
/// 4. **learned** — a count, only while the "What I learned" digest has
///    something waiting.
/// 5. The skill's markdown sections — weather, inbox, on your mind, anything
///    else as `other`. No sections at all → one `onYourMind` card.
///
/// A kind the user marked down (net up − down − dismiss ≤ −2 over 14 days)
/// moves to the bottom. Every card carries a short `why`; the brief always
/// ends with `endNote`.
///
/// Re-running the skill the same day replaces the cards and keeps the brief
/// id. A commitment already counted by today's brief is not counted again.
struct BriefComposer: Sendable {
    static let skillName = "daily-brief"
    static let endNote = "That's it for today."
    static let feedbackWindow: TimeInterval = 14 * 24 * 60 * 60
    /// Net feedback at or below this moves a kind to the bottom.
    static let demoteAtOrBelow = -2
    static let maxEventsListed = 8
    static let maxSectionLength = 1500

    let fluent: Fluent

    // MARK: - Compose

    @discardableResult
    func compose(tenantID: UUID, skillMarkdown: String, now: Date = Date()) async throws -> BriefDTO {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for briefs")
        }
        let user = try await User.find(tenantID, on: fluent.db())
        let zone = user.flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone(identifier: "UTC")!
        let day = ProactivePushBudget.localDay(now, timezone: zone.identifier)

        let previous = try await MeBriefService(fluent: fluent).brief(tenantID: tenantID, date: day)
        let alreadyCounted = Set((previous?.cards ?? [])
            .flatMap(\.refs)
            .filter { $0.kind == .commitment }
            .compactMap { UUID(uuidString: $0.id) })

        var cards: [BriefCardDTO] = []
        if let today = try await todayCard(sql, tenantID: tenantID, zone: zone, now: now) {
            cards.append(today)
        }
        let commitments = CommitmentsService(fluent: fluent)
        let loops = try await commitments.forBrief(tenantID: tenantID, alreadyCounted: alreadyCounted)
        if let card = Self.openLoopsCard(loops, zone: zone, now: now) {
            cards.append(card)
        }
        if let user, let card = try await toRevisitCard(user: user, now: now) {
            cards.append(card)
        }
        if let card = try await learnedCard(tenantID: tenantID, now: now) {
            cards.append(card)
        }
        let hasToday = cards.contains { $0.kind == .today }
        for section in Self.sections(from: skillMarkdown) where !(hasToday && section.kind == .today) {
            cards.append(Self.sectionCard(section))
        }
        cards = Self.uniqueIDs(cards)

        let net = try await netFeedback(sql, tenantID: tenantID, now: now)
        cards = Self.order(cards, net: net)

        let stored = try await upsert(sql, tenantID: tenantID, day: day, cards: cards, now: now)
        let newlyShown = loops.map(\.id).filter { !alreadyCounted.contains($0) }
        try await commitments.markSurfaced(tenantID: tenantID, ids: newlyShown)
        return stored
    }

    private func upsert(_ sql: any SQLDatabase, tenantID: UUID, day: String, cards: [BriefCardDTO], now: Date) async throws -> BriefDTO {
        struct Row: Decodable { let id: UUID; let created_at: Date }
        let json = try String(decoding: JSONEncoder().encode(cards), as: UTF8.self)
        guard let row = try await sql.raw("""
        INSERT INTO briefs (tenant_id, date, cards, end_note, created_at, updated_at)
        VALUES (\(bind: tenantID), \(bind: day)::date, \(bind: json)::jsonb, \(bind: Self.endNote), \(bind: now), \(bind: now))
        ON CONFLICT (tenant_id, date) DO UPDATE
        SET cards = EXCLUDED.cards, end_note = EXCLUDED.end_note, updated_at = EXCLUDED.updated_at
        RETURNING id, created_at
        """).first(decoding: Row.self) else {
            throw HTTPError(.internalServerError, message: "brief not stored")
        }
        return BriefDTO(id: row.id, date: day, cards: cards, endNote: Self.endNote, createdAt: row.created_at)
    }

    // MARK: - Deterministic cards

    private func todayCard(_ sql: any SQLDatabase, tenantID: UUID, zone: TimeZone, now: Date) async throws -> BriefCardDTO? {
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .calendar, sql: sql)
        guard allowed else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        struct Row: Decodable { let id: UUID; let title: String; let starts_at: Date; let all_day: Bool }
        let rows = try await sql.raw("""
        SELECT id, title, starts_at, all_day
        FROM calendar_events
        WHERE tenant_id = \(bind: tenantID)
          AND status <> 'cancelled'
          AND starts_at < \(bind: end)
          AND ends_at > \(bind: start)
        ORDER BY all_day DESC, starts_at ASC, id
        LIMIT 50
        """).all(decoding: Row.self)
        guard !rows.isEmpty else { return nil }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_GB")
        time.timeZone = zone
        time.dateFormat = "HH:mm"
        var lines = rows.prefix(Self.maxEventsListed).map { row in
            "- " + (row.all_day ? "All day" : time.string(from: row.starts_at)) + " · " + row.title
        }
        if rows.count > Self.maxEventsListed {
            lines.append("- and \(rows.count - Self.maxEventsListed) more")
        }
        let timed = rows.filter { !$0.all_day }
        let why = if let first = timed.first(where: { $0.starts_at >= now }) ?? timed.first {
            "\(Self.count(rows.count, "event")) today, first at \(time.string(from: first.starts_at))"
        } else {
            "\(Self.count(rows.count, "event")) on your calendar today"
        }
        return BriefCardDTO(
            id: BriefCardKind.today.rawValue,
            kind: .today,
            title: "Today",
            body: lines.joined(separator: "\n"),
            why: why,
            refs: rows.prefix(Self.maxEventsListed).map { BriefCardRefDTO(kind: .event, id: $0.id.uuidString) }
        )
    }

    static func openLoopsCard(_ loops: [CommitmentDTO], zone: TimeZone, now: Date) -> BriefCardDTO? {
        guard !loops.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let short = DateFormatter()
        short.locale = Locale(identifier: "en_US_POSIX")
        short.timeZone = zone
        short.dateFormat = "EEE d MMM"
        let lines = loops.map { loop in
            guard let due = loop.dueAt else { return "- \(loop.text)" }
            return "- \(loop.text) (due \(short.string(from: due)))"
        }
        let overdue = loops.count(where: { ($0.dueAt ?? .distantFuture) < today })
        let dueToday = loops.count(where: { ($0.dueAt.map { $0 >= today && $0 < tomorrow }) ?? false })
        let why = if overdue > 0 {
            "You said you'd do these — \(overdue == 1 ? "one is" : "\(overdue) are") overdue"
        } else if dueToday > 0 {
            "You said you'd do these — \(dueToday == 1 ? "one is" : "\(dueToday) are") due today"
        } else {
            "Things you said you'd do"
        }
        return BriefCardDTO(
            id: BriefCardKind.openLoops.rawValue,
            kind: .openLoops,
            title: "Open loops",
            body: lines.joined(separator: "\n"),
            why: why,
            refs: loops.map { BriefCardRefDTO(kind: .commitment, id: $0.id.uuidString) }
        )
    }

    private func toRevisitCard(user: User, now: Date) async throws -> BriefCardDTO? {
        guard let item = try await MeResurfaceService(fluent: fluent).build(user: user, limit: 1, now: now).items.first else {
            return nil
        }
        return BriefCardDTO(
            id: BriefCardKind.toRevisit.rawValue,
            kind: .toRevisit,
            title: "To revisit",
            body: item.snippet,
            why: item.why,
            refs: [BriefCardRefDTO(kind: .memory, id: item.memoryId.uuidString)]
        )
    }

    private func learnedCard(tenantID: UUID, now: Date) async throws -> BriefCardDTO? {
        let digest = try await MeLearnedService(fluent: fluent).build(
            tenantID: tenantID,
            since: now.addingTimeInterval(-MeLearnedService.defaultWindow),
            now: now
        )
        guard let body = MeLearnedService.pushBody(for: digest) else { return nil }
        let refs = digest.soulChanges.map { BriefCardRefDTO(kind: .soulChange, id: $0.id.uuidString) }
            + digest.memories.map { BriefCardRefDTO(kind: .memory, id: $0.id.uuidString) }
        return BriefCardDTO(
            id: BriefCardKind.learned.rawValue,
            kind: .learned,
            title: "What I learned",
            body: body,
            why: "Picked up this week and waiting for you to confirm",
            refs: refs
        )
    }

    // MARK: - Ordering

    private func netFeedback(_ sql: any SQLDatabase, tenantID: UUID, now: Date) async throws -> [String: Int] {
        struct Row: Decodable { let card_kind: String; let net: Int }
        let rows = try await sql.raw("""
        SELECT card_kind,
               SUM(CASE WHEN action = 'up' THEN 1 ELSE -1 END)::int AS net
        FROM brief_feedback
        WHERE tenant_id = \(bind: tenantID)
          AND created_at >= \(bind: now.addingTimeInterval(-Self.feedbackWindow))
        GROUP BY card_kind
        """).all(decoding: Row.self)
        return Dictionary(rows.map { ($0.card_kind, $0.net) }, uniquingKeysWith: +)
    }

    /// Stable: kinds at or below the threshold keep their relative order,
    /// after everything else.
    static func order(_ cards: [BriefCardDTO], net: [String: Int]) -> [BriefCardDTO] {
        let demoted = { (card: BriefCardDTO) in (net[card.kind.rawValue] ?? 0) <= demoteAtOrBelow }
        return cards.filter { !demoted($0) } + cards.filter(demoted)
    }

    /// Card ids are the kind; a second card of the same kind gets `-2`, …
    static func uniqueIDs(_ cards: [BriefCardDTO]) -> [BriefCardDTO] {
        var seen: [String: Int] = [:]
        return cards.map { card in
            let n = (seen[card.kind.rawValue] ?? 0) + 1
            seen[card.kind.rawValue] = n
            guard n > 1 else { return card }
            return BriefCardDTO(id: "\(card.kind.rawValue)-\(n)", kind: card.kind, title: card.title, body: card.body, why: card.why, refs: card.refs)
        }
    }

    // MARK: - The skill's sections

    struct Section: Equatable {
        let kind: BriefCardKind
        let title: String
        let body: String
    }

    /// Splits the skill's markdown on its section labels: a heading
    /// (`## Weather`) or a bold label on its own line (`**Weather**`, also
    /// `**Weather:** text` with the text kept). Text before the first label
    /// is the greeting and is dropped when there are labels; with no labels
    /// at all, the whole text is one `onYourMind` section. Empty sections
    /// are skipped.
    static func sections(from markdown: String) -> [Section] {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var found: [(title: String, lines: [String])] = []
        var current: (title: String, lines: [String])?
        var sawLabel = false
        for line in text.components(separatedBy: .newlines) {
            if let (title, rest) = label(in: line) {
                if let current {
                    found.append(current)
                }
                current = (title, rest.isEmpty ? [] : [rest])
                sawLabel = true
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        if let current {
            found.append(current)
        }
        guard sawLabel else {
            return [Section(kind: .onYourMind, title: "On your mind", body: clip(text))]
        }
        return found.compactMap { entry in
            let body = entry.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return Section(kind: kind(forHeading: entry.title), title: entry.title, body: clip(body))
        }
    }

    /// `## Title`, `**Title**`, `**Title:** rest`, `**Title** — rest`.
    static func label(in rawLine: String) -> (title: String, rest: String)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            let cleaned = title.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return cleaned.isEmpty ? nil : (cleaned, "")
        }
        guard line.hasPrefix("**") else { return nil }
        let afterOpen = line.dropFirst(2)
        guard let close = afterOpen.range(of: "**") else { return nil }
        let title = afterOpen[..<close.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        // A bold phrase inside a longer sentence is emphasis, not a label.
        guard !title.isEmpty, title.count <= 40 else { return nil }
        let rest = afterOpen[close.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ":—–- ").union(.whitespaces))
        let titleEndsInColon = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix(":")
        let restStartsLikeLabel = afterOpen[close.upperBound...].trimmingCharacters(in: .whitespaces)
            .first.map { ":—–-".contains($0) } ?? true
        guard rest.isEmpty || titleEndsInColon || restStartsLikeLabel else { return nil }
        return (title, rest)
    }

    static func kind(forHeading heading: String) -> BriefCardKind {
        let h = heading.lowercased()
        if h.contains("weather") || h.contains("forecast") {
            return .weather
        }
        if h.contains("inbox") || h.contains("mail") {
            return .inbox
        }
        if h.contains("on your mind") || h.contains("mind") {
            return .onYourMind
        }
        if h == "today" || h.contains("schedule") || h.contains("calendar") {
            return .today
        }
        return .other
    }

    static func sectionCard(_ section: Section) -> BriefCardDTO {
        let why = switch section.kind {
        case .weather: "For planning your day"
        case .inbox: "Messages that look like they need you"
        case .onYourMind: "From your recent notes"
        case .today: "On your calendar today"
        default: "From your morning brief"
        }
        return BriefCardDTO(id: section.kind.rawValue, kind: section.kind, title: section.title, body: section.body, why: why)
    }

    private static func clip(_ text: String) -> String {
        text.count > maxSectionLength ? String(text.prefix(maxSectionLength - 1)) + "…" : text
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
