import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// Commitments ("open loops"): first-person promises kb-compile pulls out of
/// notes. Stored in `commitments` (M146); read and closed through
/// `GET/PATCH /v1/me/commitments`; up to three at a time ride in the daily
/// brief (`BriefComposer`), each in at most `maxBriefAppearances` briefs.
///
/// Deterministic SQL, no model call. The model call is kb-compile's, which
/// already runs; this only stores what it returned.
struct CommitmentsService {
    let fluent: Fluent

    /// A commitment stops appearing in briefs after this many (no nagging).
    static let maxBriefAppearances = 3
    /// Open loops shown per brief.
    static let briefLimit = 3
    /// Longest commitment text kept.
    static let maxTextLength = 500
    /// Most commitments kept from one kb-compile response.
    static let maxPerCompile = 20

    /// One commitment as the model returned it, already cleaned up.
    struct Extracted: Equatable {
        let text: String
        let due: Date?
        /// The file path the model says it came from; trusted only when it is
        /// one of the files in the batch.
        let source: String?
    }

    /// Something to store: an extracted commitment with its lineage resolved.
    struct NewCommitment {
        let text: String
        let due: Date?
        let memoryID: UUID?
        let sourceVaultFileID: UUID?
    }

    struct Row: Decodable {
        let id: UUID
        let text: String
        let due_at: Date?
        let state: String
        let surfaced_count: Int
        let memory_id: UUID?
        let source_vault_file_id: UUID?
        let created_at: Date
        let done_at: Date?

        var dto: CommitmentDTO {
            CommitmentDTO(
                id: id,
                text: text,
                dueAt: due_at,
                state: CommitmentState(rawValue: state) ?? .unknown,
                surfacedCount: surfaced_count,
                memoryId: memory_id,
                sourceVaultFileId: source_vault_file_id,
                createdAt: created_at,
                doneAt: done_at
            )
        }
    }

    static let columns = "id, text, due_at, state, surfaced_count, memory_id, source_vault_file_id, created_at, done_at"

    private func sql() throws -> any SQLDatabase {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for commitments")
        }
        return sql
    }

    // MARK: - Write (kb-compile)

    /// Stores new open commitments. One already open with the same
    /// normalized text is left alone (partial unique index, M146), so a
    /// re-compile of the same note adds nothing. Returns how many were new.
    @discardableResult
    func record(tenantID: UUID, _ items: [NewCommitment], now: Date = Date()) async throws -> Int {
        let sql = try sql()
        var inserted = 0
        for item in items.prefix(Self.maxPerCompile) {
            let normalized = Self.normalize(item.text)
            guard !normalized.isEmpty else { continue }
            let row = try await sql.raw("""
            INSERT INTO commitments (tenant_id, memory_id, source_vault_file_id, text, normalized_text, due_at, state, created_at)
            VALUES (\(bind: tenantID), \(bind: item.memoryID), \(bind: item.sourceVaultFileID), \(bind: item.text),
                    \(bind: normalized), \(bind: item.due), 'open', \(bind: now))
            ON CONFLICT (tenant_id, normalized_text) WHERE state = 'open' DO NOTHING
            RETURNING id
            """).first()
            if row != nil {
                inserted += 1
            }
        }
        return inserted
    }

    // MARK: - Read / update (API)

    enum Filter: String {
        case open, done, dropped, all
    }

    /// Open ones: due first (soonest), then oldest. Closed ones: most
    /// recently closed first. Capped at 200.
    func list(tenantID: UUID, filter: Filter) async throws -> [CommitmentDTO] {
        let sql = try sql()
        let rows: [Row] = switch filter {
        case .all:
            try await sql.raw("""
            SELECT \(unsafeRaw: Self.columns) FROM commitments
            WHERE tenant_id = \(bind: tenantID)
            ORDER BY (state = 'open') DESC, due_at ASC NULLS LAST, created_at DESC, id
            LIMIT 200
            """).all(decoding: Row.self)
        case .open:
            try await sql.raw("""
            SELECT \(unsafeRaw: Self.columns) FROM commitments
            WHERE tenant_id = \(bind: tenantID) AND state = 'open'
            ORDER BY due_at ASC NULLS LAST, created_at ASC, id
            LIMIT 200
            """).all(decoding: Row.self)
        case .done, .dropped:
            try await sql.raw("""
            SELECT \(unsafeRaw: Self.columns) FROM commitments
            WHERE tenant_id = \(bind: tenantID) AND state = \(bind: filter.rawValue)
            ORDER BY done_at DESC NULLS LAST, created_at DESC, id
            LIMIT 200
            """).all(decoding: Row.self)
        }
        return rows.map(\.dto)
    }

    /// Moves a commitment to `state`. `done` and `dropped` stamp `done_at`;
    /// back to `open` clears it. Nil when the id is not the tenant's. A
    /// reopen that collides with another open commitment of the same text
    /// is a 409.
    func update(tenantID: UUID, id: UUID, state: CommitmentState, now: Date = Date()) async throws -> CommitmentDTO? {
        guard state == .open || state == .done || state == .dropped else {
            throw HTTPError(.badRequest, message: "state must be open, done or dropped")
        }
        let sql = try sql()
        if state == .open {
            struct Clash: Decodable { let id: UUID }
            let clash = try await sql.raw("""
            SELECT other.id FROM commitments me
            JOIN commitments other
              ON other.tenant_id = me.tenant_id
             AND other.normalized_text = me.normalized_text
             AND other.state = 'open'
             AND other.id <> me.id
            WHERE me.tenant_id = \(bind: tenantID) AND me.id = \(bind: id)
            LIMIT 1
            """).first(decoding: Clash.self)
            if clash != nil {
                throw HTTPError(.conflict, message: "an open commitment with the same text already exists")
            }
        }
        return try await sql.raw("""
        UPDATE commitments
        SET done_at = CASE WHEN \(bind: state.rawValue) = 'open' THEN NULL
                           WHEN state = \(bind: state.rawValue) THEN done_at
                           ELSE \(bind: now) END,
            state = \(bind: state.rawValue)
        WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id)
        RETURNING \(unsafeRaw: Self.columns)
        """).first(decoding: Row.self)?.dto
    }

    // MARK: - Brief

    /// Up to `briefLimit` open commitments for today's brief: due first, then
    /// oldest, among those shown in fewer than `maxBriefAppearances` briefs.
    /// `alreadyCounted` are the ones today's brief already showed (a same-day
    /// re-run): they stay eligible whatever their count, because this brief
    /// already paid for them.
    func forBrief(tenantID: UUID, alreadyCounted: Set<UUID>) async throws -> [CommitmentDTO] {
        let sql = try sql()
        let counted = Array(alreadyCounted)
        return try await sql.raw("""
        SELECT \(unsafeRaw: Self.columns) FROM commitments
        WHERE tenant_id = \(bind: tenantID) AND state = 'open'
          AND (surfaced_count < \(bind: Self.maxBriefAppearances) OR id = ANY(\(bind: counted)))
        ORDER BY due_at ASC NULLS LAST, created_at ASC, id
        LIMIT \(bind: Self.briefLimit)
        """).all(decoding: Row.self).map(\.dto)
    }

    /// Counts one more brief appearance for each of `ids`.
    func markSurfaced(tenantID: UUID, ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await sql().raw("""
        UPDATE commitments SET surfaced_count = surfaced_count + 1
        WHERE tenant_id = \(bind: tenantID) AND id = ANY(\(bind: ids))
        """).run()
    }

    // MARK: - Parsing

    /// Lowercased, whitespace collapsed, trailing punctuation dropped:
    /// "I'll call Mum. " and "i'll call mum" are the same promise.
    static func normalize(_ text: String) -> String {
        let collapsed = text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".!;:,").union(.whitespaces))
    }

    /// `yyyy-MM-dd` → that day at 12:00 UTC (noon keeps it on the same
    /// calendar day for every timezone within ±12h); a full ISO 8601
    /// date-time as given. Anything else — prose, "Friday", "" — is nil.
    static func parseDue(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let day = formatter.date(from: trimmed) else { return nil }
            return day.addingTimeInterval(12 * 60 * 60)
        }
        return MeLearnedController.parseISO8601(trimmed)
    }
}

extension MemoryCompileService {
    /// The `commitments` half of the kb-compile response,
    /// `{"memories": [...], "commitments": [{"text", "due", "source"}]}`.
    ///
    /// Lenient by design — a commitment is a bonus, never a reason to fail
    /// a compile: no `commitments` key, a key that is not an array, or a
    /// response that is not JSON at all → `[]`. Entries without usable text
    /// are skipped; an unparsable `due` is nil. Tolerates the same code
    /// fences and surrounding prose as `parseExtractedItems`.
    static func parseExtractedCommitments(_ raw: String) -> [CommitmentsService.Extracted] {
        func commitments(from obj: Any) -> [CommitmentsService.Extracted]? {
            guard let dict = obj as? [String: Any] else { return nil }
            guard let arr = dict["commitments"] as? [Any] else { return [] }
            return arr.compactMap { entry in
                let text: String? = if let str = entry as? String {
                    str
                } else if let item = entry as? [String: Any] {
                    (item["text"] ?? item["content"]) as? String
                } else {
                    nil
                }
                guard let text else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let item = entry as? [String: Any]
                return CommitmentsService.Extracted(
                    text: String(trimmed.prefix(CommitmentsService.maxTextLength)),
                    due: CommitmentsService.parseDue(item?["due"]),
                    source: item?["source"] as? String
                )
            }
        }

        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let result = commitments(from: obj)
        {
            return result
        }
        if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi,
           let data = String(s[lo ... hi]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let result = commitments(from: obj)
        {
            return result
        }
        return []
    }
}
