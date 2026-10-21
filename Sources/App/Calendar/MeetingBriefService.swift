import FluentKit
import Foundation
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// The notes that bear on one upcoming meeting — what the pre-meeting push
/// counts and what `GET /v1/calendar/events/{id}/brief` shows.
///
/// No LLM. One embedding call per event: the query is the event's title, the
/// attendees' names and its notes, run once through `HybridMemorySearch` with
/// a strict cosine-distance floor (`meeting.brief.maxDistance`). Everything a
/// user reads — the push title and body, the why line — is assembled from
/// counts and attendee names, deterministically.
///
/// ## The floor
/// `defaultMaxDistance` is 0.40 (cosine similarity ≥ 0.60), tighter than the
/// 0.45 of "connects to" (`memory.related.maxDistance`). "Connects to" is a
/// chip on a screen the user already opened; this is a push 30 minutes before
/// a meeting, and the only thing worse than no brief is a brief of loosely
/// related notes. A hit the lexical arm found on its own carries distance 1.0
/// (`MemoryChunkRepository`), so a name match with no semantic match never
/// passes either.
struct MeetingBriefService: Sendable {
    let fluent: Fluent
    let embeddings: any EmbeddingService
    let search: HybridMemorySearch
    var maxDistance: Float = MeetingBriefService.defaultMaxDistance

    static let defaultMaxDistance: Float = 0.40
    static let maxMemories = 5
    /// Candidates asked of the search before the floor and the cut to five.
    static let candidateLimit = 10
    /// Long invites (dial-in blurbs, agendas) would drown the title and names.
    static let maxNotesInQuery = 600

    /// A calendar event as the brief needs it.
    struct Event: Sendable, Equatable {
        let id: UUID
        let tenantID: UUID
        let title: String
        let notes: String?
        let location: String?
        let startsAt: Date
        let endsAt: Date
        let attendees: [CalendarAttendeeDTO]
    }

    /// One note that passed the floor. Also the stored form in
    /// `meeting_briefs.memories`.
    struct Match: Codable, Sendable, Equatable {
        let id: UUID
        let similarity: Double
    }

    // MARK: - Loading

    /// The tenant's event, or nil when it is not theirs.
    func event(tenantID: UUID, eventID: UUID) async throws -> Event? {
        guard let row = try await CalendarEvent.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == eventID)
            .first()
        else { return nil }
        return try Self.event(from: row)
    }

    static func event(from row: CalendarEvent) throws -> Event {
        try Event(
            id: row.requireID(),
            tenantID: row.tenantID,
            title: row.title,
            notes: row.notes,
            location: row.location,
            startsAt: row.startsAt,
            endsAt: row.endsAt,
            attendees: attendees(from: row.attendees)
        )
    }

    static func attendees(from stored: CalendarAttendees?) -> [CalendarAttendeeDTO] {
        (stored?.list ?? []).map { CalendarAttendeeDTO(name: $0.displayName, email: $0.email) }
    }

    /// `calendar_events.attendees` as raw JSON text (`attendees::text`).
    static func attendees(fromJSON json: String?) -> [CalendarAttendeeDTO] {
        guard let json, let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(CalendarAttendees.self, from: data)
        else { return [] }
        return attendees(from: stored)
    }

    // MARK: - Matching

    /// Embeds the event once and keeps the notes within the floor, nearest
    /// first, at most five. `selfEmail` is the user's own address, left out
    /// of the query (every invite lists its owner).
    func matches(for event: Event, selfEmail: String?) async throws -> [Match] {
        let query = Self.queryText(for: event, selfEmail: selfEmail)
        guard !query.isEmpty else { return [] }
        let vector = try await embeddings.embed(query, tenantID: event.tenantID)
        let hits = try await search.search(
            tenantID: event.tenantID,
            query: query,
            queryEmbedding: vector,
            limit: Self.candidateLimit,
            countHits: false
        )
        return Self.floor(hits, maxDistance: maxDistance)
    }

    /// Within `maxDistance`, one per memory (the nearest), nearest first, ≤ 5.
    static func floor(_ hits: [MemorySearchResult], maxDistance: Float) -> [Match] {
        var best: [UUID: Float] = [:]
        for hit in hits where hit.distance <= maxDistance {
            best[hit.id] = min(best[hit.id] ?? hit.distance, hit.distance)
        }
        return best
            .sorted { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value < $1.value }
            .prefix(maxMemories)
            .map { Match(id: $0.key, similarity: max(0, min(1, 1 - Double($0.value)))) }
    }

    /// Title, attendee names, then notes — one line each, blanks dropped.
    static func queryText(for event: Event, selfEmail: String?) -> String {
        let names = people(event.attendees, selfEmail: selfEmail).map(\.full)
        let notes = event.notes.map { String(flatten($0).prefix(maxNotesInQuery)) }
        return [flatten(event.title), names.joined(separator: ", "), notes ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - The response

    /// The brief for the tenant's event: the notes the push promised when
    /// there was one (`meeting_briefs.memories`), else matched now. Nil when
    /// the event is not the tenant's.
    func brief(tenantID: UUID, eventID: UUID) async throws -> MeetingBriefResponse? {
        guard let event = try await event(tenantID: tenantID, eventID: eventID) else { return nil }
        let selfEmail = try await email(of: tenantID)
        var matches = try await stored(tenantID: tenantID, eventID: eventID)
        if matches.isEmpty {
            matches = try await self.matches(for: event, selfEmail: selfEmail)
        }
        let rows = try await memories(tenantID: tenantID, ids: matches.map(\.id))
        // A note rejected or deleted since the push is no longer shown.
        let kept = matches.compactMap { match in rows[match.id].map { (match, $0) } }
        let names = Self.mentionedNames(
            attendees: event.attendees,
            selfEmail: selfEmail,
            contents: kept.map(\.1.content)
        )
        return MeetingBriefResponse(
            event: MeetingBriefEventDTO(
                id: event.id,
                title: event.title,
                startsAt: event.startsAt,
                endsAt: event.endsAt,
                location: event.location,
                attendees: event.attendees
            ),
            memories: kept.map { match, row in
                MeetingBriefMemoryDTO(
                    id: match.id,
                    snippet: MemoryController.relatedSnippet(row.content),
                    kind: row.kind,
                    createdAt: row.createdAt ?? Date(timeIntervalSince1970: 0),
                    similarity: match.similarity
                )
            },
            why: Self.why(count: kept.count, mentioned: names)
        )
    }

    private func stored(tenantID: UUID, eventID: UUID) async throws -> [Match] {
        guard let sql = fluent.db() as? any SQLDatabase else { return [] }
        struct Row: Decodable { let memories: String }
        guard let row = try await sql.raw("""
        SELECT memories::text AS memories FROM meeting_briefs
        WHERE tenant_id = \(bind: tenantID) AND event_id = \(bind: eventID)
        """).first(decoding: Row.self) else { return [] }
        return (try? JSONDecoder().decode([Match].self, from: Data(row.memories.utf8))) ?? []
    }

    /// Content of the tenant's own, non-rejected memories among `ids`.
    func memories(tenantID: UUID, ids: [UUID]) async throws -> [UUID: Memory] {
        guard !ids.isEmpty else { return [:] }
        let rows = try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id ~~ ids)
            .filter(\.$reviewState != MemoryReviewState.rejected)
            .all()
        return Dictionary(rows.compactMap { row in row.id.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

    func email(of tenantID: UUID) async throws -> String? {
        try await User.find(tenantID, on: fluent.db())?.email
    }

    // MARK: - Words

    /// "Before Q4 plan".
    static func pushTitle(eventTitle: String) -> String {
        let title = flatten(eventTitle)
        guard !title.isEmpty else { return "Before your meeting" }
        return "Before " + (title.count > 80 ? String(title.prefix(79)) + "…" : title)
    }

    /// "3 notes on Ana and Rui" / "1 note on Ana" / "2 notes for this meeting".
    /// Counts and attendee names only — never note text, which would show on
    /// a locked screen.
    static func pushBody(count: Int, mentioned: [String]) -> String {
        let notes = count == 1 ? "1 note" : "\(count) notes"
        switch mentioned.count {
        case 0: return "\(notes) for this meeting"
        case 1: return "\(notes) on \(mentioned[0])"
        default: return "\(notes) on \(mentioned[0]) and \(mentioned[1])"
        }
    }

    /// "You mentioned Ana in 3 notes" when an attendee is named in the
    /// matched notes, else "3 notes match this meeting".
    static func why(count: Int, mentioned: [(name: String, count: Int)]) -> String {
        guard count > 0 else { return "Nothing in your notes matches this meeting yet" }
        if let top = mentioned.first {
            return "You mentioned \(top.name) in \(top.count == 1 ? "1 note" : "\(top.count) notes")"
        }
        return count == 1 ? "1 note matches this meeting" : "\(count) notes match this meeting"
    }

    /// Attendees named in `contents`, with how many notes name them, most
    /// first (ties keep invite order). Shown by first name.
    static func mentionedNames(
        attendees: [CalendarAttendeeDTO],
        selfEmail: String?,
        contents: [String]
    ) -> [(name: String, count: Int)] {
        let folded = contents.map(fold)
        let counted = people(attendees, selfEmail: selfEmail).compactMap { person -> (name: String, count: Int)? in
            let needles = Set([person.full, person.first].map(fold)).filter { $0.count >= 2 }
            let count = folded.count(where: { content in needles.contains { containsWord($0, in: content) } })
            return count > 0 ? (person.first, count) : nil
        }
        return counted.enumerated()
            .sorted { $0.element.count == $1.element.count ? $0.offset < $1.offset : $0.element.count > $1.element.count }
            .map(\.element)
    }

    /// Named attendees other than the user, de-duplicated.
    static func people(_ attendees: [CalendarAttendeeDTO], selfEmail: String?) -> [(full: String, first: String)] {
        let me = selfEmail.map { $0.lowercased() }
        var seen = Set<String>()
        return attendees.compactMap { attendee in
            if let email = attendee.email?.lowercased(), email == me {
                return nil
            }
            let full = flatten(attendee.name ?? "")
            guard !full.isEmpty, seen.insert(fold(full)).inserted else { return nil }
            let first = full.split(separator: " ").first.map(String.init) ?? full
            return (full, first)
        }
    }

    private static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `needle` in `haystack` with no letter or digit either side.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        var searchRange = haystack.startIndex ..< haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let before = found.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: found.lowerBound)]
            let after = found.upperBound == haystack.endIndex ? nil : haystack[found.upperBound]
            if !(before?.isLetter ?? false), !(before?.isNumber ?? false),
               !(after?.isLetter ?? false), !(after?.isNumber ?? false)
            {
                return true
            }
            searchRange = haystack.index(after: found.lowerBound) ..< haystack.endIndex
        }
        return false
    }
}
