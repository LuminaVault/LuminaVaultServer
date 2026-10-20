import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// Reads the day's brief and records 👍 / 👎 / dismiss on its cards.
/// `BriefComposer` writes the brief; this never calls a model.
struct MeBriefService {
    let fluent: Fluent

    private struct Row: Decodable {
        let id: UUID
        let date: String
        let cards: String
        let end_note: String
        let created_at: Date
    }

    private func sql() throws -> any SQLDatabase {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for briefs")
        }
        return sql
    }

    /// The tenant's brief for local day `date` (`yyyy-MM-dd`), nil when none.
    func brief(tenantID: UUID, date: String) async throws -> BriefDTO? {
        try await sql().raw("""
        SELECT id, date::text AS date, cards::text AS cards, end_note, created_at
        FROM briefs
        WHERE tenant_id = \(bind: tenantID) AND date = \(bind: date)::date
        """).first(decoding: Row.self).map(Self.dto)
    }

    private func brief(tenantID: UUID, id: UUID) async throws -> BriefDTO? {
        try await sql().raw("""
        SELECT id, date::text AS date, cards::text AS cards, end_note, created_at
        FROM briefs
        WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id)
        """).first(decoding: Row.self).map(Self.dto)
    }

    private static func dto(_ row: Row) -> BriefDTO {
        let cards = (try? JSONDecoder().decode([BriefCardDTO].self, from: Data(row.cards.utf8))) ?? []
        return BriefDTO(id: row.id, date: row.date, cards: cards, endNote: row.end_note, createdAt: row.created_at)
    }

    /// Records `action` on one card. A second tap on the same card replaces
    /// the first. A `down` on a "to revisit" card also means "later" for its
    /// memory — the same 30-day snooze as `POST /v1/memory/:id/review
    /// {"action":"later"}`. Throws 404 when the brief is not the tenant's or
    /// the card is not in it.
    func feedback(
        tenantID: UUID,
        briefID: UUID,
        cardID: String,
        action: BriefCardFeedbackAction,
        actorUserID: UUID,
        now: Date = Date()
    ) async throws {
        guard let brief = try await brief(tenantID: tenantID, id: briefID),
              let card = brief.cards.first(where: { $0.id == cardID })
        else {
            throw HTTPError(.notFound, message: "brief card not found")
        }
        try await sql().raw("""
        INSERT INTO brief_feedback (tenant_id, brief_id, card_id, card_kind, action, created_at)
        VALUES (\(bind: tenantID), \(bind: briefID), \(bind: cardID), \(bind: card.kind.rawValue), \(bind: action.rawValue), \(bind: now))
        ON CONFLICT (brief_id, card_id) DO UPDATE
        SET action = EXCLUDED.action, created_at = EXCLUDED.created_at
        """).run()

        guard action == .down, card.kind == .toRevisit else { return }
        let db = fluent.db()
        for ref in card.refs where ref.kind == .memory {
            guard let memoryID = UUID(uuidString: ref.id),
                  let row = try await Memory.query(on: db, tenantID: tenantID).filter(\.$id == memoryID).first()
            else { continue }
            row.lastReviewedAt = now
            row.reviewCount += 1
            MemoryController.applyReviewAction(.later, to: row, now: now)
            row.updatedByUserID = actorUserID
            try await row.update(on: db)
        }
    }
}
