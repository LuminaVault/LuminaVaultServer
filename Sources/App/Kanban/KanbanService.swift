import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

struct KanbanService {
    let fluent: Fluent
    /// Authors promoted cards as vault cron skills. Optional so plain board
    /// callers/tests can construct the service without the Jobs subsystem;
    /// `promoteCard` requires it.
    var authoring: JobAuthoring?
    private var db: any Database {
        fluent.db()
    }

    /// Outcome of promoting a card to a scheduled Job. Carries enough to build
    /// the `SkillDTO` response without a `CardDTO`/Shared change.
    struct PromotedJob {
        let slug: String
        let title: String
        /// Cron for recurring jobs; nil for one-shot (#10).
        let cron: String?
        /// Fire time for one-shot jobs; nil for recurring.
        let runAt: Date?
        let spec: String
        /// True when the card already had a `jobSlug` — no re-author happened.
        let alreadyPromoted: Bool
    }

    // MARK: - Boards

    func createBoard(tenantID: UUID, title: String) async throws -> KanbanBoard {
        let b = KanbanBoard(); b.tenantID = tenantID; b.title = title; b.version = 0
        try await b.save(on: db); return b
    }

    func listBoards(tenantID: UUID) async throws -> [BoardSummaryDTO] {
        let boards = try await KanbanBoard.query(on: db)
            .filter(\.$tenantID == tenantID).filter(\.$archivedAt == nil).all()
        var out: [BoardSummaryDTO] = []
        for b in boards {
            let bid = try b.requireID()
            let cols = try await KanbanColumn.query(on: db).filter(\.$boardID == bid).count()
            let cards = try await KanbanCard.query(on: db).filter(\.$boardID == bid).count()
            out.append(BoardSummaryDTO(id: bid, title: b.title, version: b.version,
                                       columnCount: cols, cardCount: cards, updatedAt: b.updatedAt))
        }
        return out
    }

    func defaultBoard(tenantID: UUID) async throws -> KanbanBoard {
        if let existing = try await KanbanBoard.query(on: db)
            .filter(\.$tenantID == tenantID).filter(\.$archivedAt == nil)
            .sort(\.$createdAt).first()
        {
            return existing
        }
        let b = try await createBoard(tenantID: tenantID, title: "My Board")
        for t in ["Todo", "Doing", "Done"] {
            _ = try await createColumn(tenantID: tenantID, boardID: b.requireID(), title: t)
        }
        return b
    }

    func patchBoard(tenantID: UUID, boardID: UUID, req: BoardPatchRequest,
                    expectedVersion: Int64? = nil) async throws -> BoardDTO
    {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let b = try await requireBoard(tenantID: tenantID, boardID: boardID, on: database)
            if let t = req.title {
                b.title = t
            }
            if req.archived == true {
                b.archivedAt = Date()
            }
            try await b.update(on: database)
        }
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    func deleteBoard(tenantID: UUID, boardID: UUID, expectedVersion: Int64? = nil) async throws {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let b = try await requireBoard(tenantID: tenantID, boardID: boardID, on: database)
            try await b.delete(on: database)
        }
    }

    // MARK: - Columns

    func createColumn(tenantID: UUID, boardID: UUID, title: String,
                      expectedVersion: Int64? = nil) async throws -> KanbanColumn
    {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let last = try await KanbanColumn.query(on: database).filter(\.$boardID == boardID)
                .sort(\.$rank, .descending).first()
            let c = KanbanColumn()
            c.tenantID = tenantID; c.boardID = boardID; c.title = title
            c.rank = RankString.between(last?.rank, nil)
            try await c.save(on: database)
            return c
        }
    }

    func patchColumn(tenantID: UUID, boardID: UUID, columnID: UUID, title: String,
                     expectedVersion: Int64? = nil) async throws -> BoardDTO
    {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let c = try await requireColumn(tenantID: tenantID, columnID: columnID, on: database)
            guard c.boardID == boardID else { throw HTTPError(.notFound, message: "column_not_found") }
            c.title = title
            try await c.update(on: database)
        }
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    func deleteColumn(tenantID: UUID, boardID: UUID, columnID: UUID,
                      expectedVersion: Int64? = nil) async throws -> BoardDTO
    {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let c = try await requireColumn(tenantID: tenantID, columnID: columnID, on: database)
            guard c.boardID == boardID else { throw HTTPError(.notFound, message: "column_not_found") }
            try await c.delete(on: database)
        }
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    func reorderColumn(tenantID: UUID, boardID: UUID, req: ColumnReorderRequest,
                       expectedVersion: Int64? = nil) async throws -> BoardDTO
    {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let c = try await requireColumn(tenantID: tenantID, columnID: req.columnID, on: database)
            guard c.boardID == boardID else { throw HTTPError(.notFound, message: "column_not_found") }
            let before = try await siblingColumn(req.beforeID, boardID: boardID, on: database)
            let after = try await siblingColumn(req.afterID, boardID: boardID, on: database)
            c.rank = RankString.between(before?.rank, after?.rank)
            try await c.update(on: database)
        }
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    // MARK: - Cards

    func createCard(tenantID: UUID, boardID: UUID, columnID: UUID, req: CardCreateRequest,
                    expectedVersion: Int64? = nil) async throws -> KanbanCard
    {
        try await db.transaction { database in
            _ = try await claimMutation(tenantID: tenantID, boardID: boardID,
                                        expectedVersion: expectedVersion, on: database)
            let column = try await requireColumn(tenantID: tenantID, columnID: columnID, on: database)
            guard column.boardID == boardID else { throw HTTPError(.notFound, message: "column_not_found") }
            let last = try await KanbanCard.query(on: database).filter(\.$columnID == columnID)
                .sort(\.$rank, .descending).first()
            let card = KanbanCard()
            card.tenantID = tenantID; card.boardID = boardID; card.columnID = columnID
            card.title = req.title; card.body = req.body
            card.priority = req.priority?.rawValue; card.dueAt = req.dueAt
            card.rank = RankString.between(last?.rank, nil)
            try await card.save(on: database)
            return card
        }
    }

    func patchCard(tenantID: UUID, cardID: UUID, req: CardPatchRequest,
                   expectedVersion: Int64? = nil) async throws -> CardDTO
    {
        try await db.transaction { database in
            let card = try await requireCard(tenantID: tenantID, cardID: cardID, on: database)
            _ = try await claimMutation(tenantID: tenantID, boardID: card.boardID,
                                        expectedVersion: expectedVersion, on: database)
            if let t = req.title {
                card.title = t
            }
            if let b = req.body {
                card.body = b
            }
            if let p = req.priority {
                card.priority = p.rawValue
            }
            if let d = req.dueAt {
                card.dueAt = d
            }
            try await card.update(on: database)
            return Self.cardDTO(card)
        }
    }

    func deleteCard(tenantID: UUID, cardID: UUID, expectedVersion: Int64? = nil) async throws {
        try await db.transaction { database in
            let card = try await requireCard(tenantID: tenantID, cardID: cardID, on: database)
            _ = try await claimMutation(tenantID: tenantID, boardID: card.boardID,
                                        expectedVersion: expectedVersion, on: database)
            try await card.delete(on: database)
        }
    }

    func moveCard(tenantID: UUID, cardID: UUID, req: CardMoveRequest,
                  expectedVersion: Int64? = nil) async throws -> CardDTO
    {
        try await db.transaction { database in
            let card = try await requireCard(tenantID: tenantID, cardID: cardID, on: database)
            _ = try await claimMutation(tenantID: tenantID, boardID: card.boardID,
                                        expectedVersion: expectedVersion, on: database)
            let column = try await requireColumn(tenantID: tenantID, columnID: req.toColumnID, on: database)
            guard column.boardID == card.boardID else { throw HTTPError(.notFound, message: "column_not_found") }
            let before = try await siblingCard(req.beforeID, columnID: req.toColumnID, on: database)
            let after = try await siblingCard(req.afterID, columnID: req.toColumnID, on: database)
            card.columnID = req.toColumnID
            card.rank = RankString.between(before?.rank, after?.rank)
            try await card.update(on: database)
            return Self.cardDTO(card)
        }
    }

    // MARK: - Promotion (card → Job)

    /// Promotes a card to a scheduled Job (gap #1). Reads structured config from
    /// `card.extra.job`, authors a vault cron skill via `JobAuthoring`, and
    /// writes the resulting slug back onto the card. Idempotent: a card that was
    /// already promoted (has `jobSlug`) is not re-authored.
    func promoteCard(tenantID: UUID, cardID: UUID, request: CardPromoteRequest? = nil,
                     expectedVersion: Int64? = nil) async throws -> PromotedJob
    {
        try await db.transaction { database in
            guard let authoring else {
                throw HTTPError(.internalServerError, message: "job_authoring_unavailable")
            }
            let card = try await requireCard(tenantID: tenantID, cardID: cardID, on: database)
            var extra = card.extra ?? CardExtra()
            // Merge any inline request config onto the card's existing config so a
            // card can be promoted in a single call (request fields win).
            var job = extra.job ?? CardJobConfig()
            if let request {
                if let v = request.cron {
                    job.cron = v
                }
                if let v = request.runAt {
                    job.runAt = v
                }
                if let v = request.domain {
                    job.domain = v
                }
                if let v = request.prompt {
                    job.prompt = v
                }
                if let v = request.spaceID {
                    job.spaceID = v
                }
            }
            // Exactly one of cron (recurring) or run_at (one-shot, #10).
            let cron = job.cron?.trimmingCharacters(in: .whitespaces)
            let hasCron = !(cron?.isEmpty ?? true)
            let hasRunAt = job.runAt != nil
            guard hasCron != hasRunAt else {
                throw HTTPError(.badRequest, message: "card_job_requires_cron_or_run_at")
            }
            let effectiveCron = hasCron ? cron : nil
            let effectiveRunAt = hasRunAt ? job.runAt : nil
            guard let spec = (job.prompt ?? card.body)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !spec.isEmpty
            else {
                throw HTTPError(.badRequest, message: "card_job_requires_prompt_or_body")
            }

            // Idempotency: already promoted → return the existing job, no re-author.
            if let slug = job.jobSlug {
                return PromotedJob(slug: slug, title: card.title, cron: effectiveCron,
                                   runAt: effectiveRunAt, spec: spec, alreadyPromoted: true)
            }

            _ = try await claimMutation(tenantID: tenantID, boardID: card.boardID,
                                        expectedVersion: expectedVersion, on: database)
            let slug = try await authoring.author(
                tenantID: tenantID,
                title: card.title,
                cron: effectiveCron,
                runAt: effectiveRunAt,
                domain: job.domain,
                spec: spec,
                spaceID: job.spaceID
            )
            job.jobSlug = slug
            job.promotedAt = Date()
            extra.job = job
            card.extra = extra
            try await card.update(on: database)
            return PromotedJob(slug: slug, title: card.title, cron: effectiveCron,
                               runAt: effectiveRunAt, spec: spec, alreadyPromoted: false)
        }
    }

    // MARK: - Snapshot

    func snapshot(tenantID: UUID, boardID: UUID) async throws -> BoardDTO {
        let board = try await requireBoard(tenantID: tenantID, boardID: boardID)
        let columns = try await KanbanColumn.query(on: db)
            .filter(\.$boardID == boardID).sort(\.$rank).all()
        var colDTOs: [ColumnDTO] = []
        for col in columns {
            let cid = try col.requireID()
            let cards = try await KanbanCard.query(on: db)
                .filter(\.$columnID == cid).sort(\.$rank).all()
            colDTOs.append(ColumnDTO(id: cid, title: col.title, rank: col.rank,
                                     cards: cards.map(Self.cardDTO)))
        }
        return try BoardDTO(id: board.requireID(), title: board.title,
                            version: board.version, columns: colDTOs,
                            createdByUserId: board.createdByUserID,
                            updatedByUserId: board.updatedByUserID)
    }

    func version(tenantID: UUID, boardID: UUID) async throws -> Int64 {
        try await requireBoard(tenantID: tenantID, boardID: boardID).version
    }

    func boardID(tenantID: UUID, cardID: UUID) async throws -> UUID {
        try await requireCard(tenantID: tenantID, cardID: cardID).boardID
    }

    // MARK: - Helpers

    private struct ClaimedVersion: Decodable {
        let version: Int64
    }

    /// Atomically claims one board version inside the caller's transaction.
    /// A stale expected version updates no rows, so the content mutation never runs.
    private func claimMutation(tenantID: UUID, boardID: UUID, expectedVersion: Int64?,
                               on database: any Database) async throws -> Int64
    {
        guard let sql = database as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "kanban database does not support atomic mutations")
        }
        let claimed: ClaimedVersion? = if let expectedVersion {
            try await sql.raw("""
            UPDATE kanban_boards
            SET version = version + 1, updated_at = NOW()
            WHERE id = \(bind: boardID) AND tenant_id = \(bind: tenantID)
              AND version = \(bind: expectedVersion)
            RETURNING version
            """).first(decoding: ClaimedVersion.self)
        } else {
            try await sql.raw("""
            UPDATE kanban_boards
            SET version = version + 1, updated_at = NOW()
            WHERE id = \(bind: boardID) AND tenant_id = \(bind: tenantID)
            RETURNING version
            """).first(decoding: ClaimedVersion.self)
        }
        if let claimed {
            return claimed.version
        }
        if try await KanbanBoard.query(on: database)
            .filter(\.$id == boardID).filter(\.$tenantID == tenantID).first() == nil
        {
            throw HTTPError(.notFound, message: "board_not_found")
        }
        throw HTTPError(.conflict, message: "board_version_conflict")
    }

    private static func cardDTO(_ c: KanbanCard) -> CardDTO {
        let priority: CardPriority? = if let raw = c.priority {
            CardPriority(rawValue: raw)
        } else {
            nil
        }
        let jobConfig = c.extra?.job.map {
            CardJobConfigDTO(
                source: $0.source, cron: $0.cron, runAt: $0.runAt, domain: $0.domain,
                prompt: $0.prompt, spaceID: $0.spaceID, jobSlug: $0.jobSlug, promotedAt: $0.promotedAt
            )
        }
        return CardDTO(id: c.id ?? UUID(), columnID: c.columnID, title: c.title, body: c.body,
                       priority: priority,
                       dueAt: c.dueAt, rank: c.rank, updatedAt: c.updatedAt, jobConfig: jobConfig,
                       createdByUserId: c.createdByUserID, updatedByUserId: c.updatedByUserID)
    }

    private func requireBoard(tenantID: UUID, boardID: UUID) async throws -> KanbanBoard {
        try await requireBoard(tenantID: tenantID, boardID: boardID, on: db)
    }

    private func requireBoard(tenantID: UUID, boardID: UUID,
                              on database: any Database) async throws -> KanbanBoard
    {
        guard let b = try await KanbanBoard.query(on: database)
            .filter(\.$id == boardID).filter(\.$tenantID == tenantID).first()
        else { throw HTTPError(.notFound, message: "board_not_found") }
        return b
    }

    private func requireColumn(tenantID: UUID, columnID: UUID) async throws -> KanbanColumn {
        try await requireColumn(tenantID: tenantID, columnID: columnID, on: db)
    }

    private func requireColumn(tenantID: UUID, columnID: UUID,
                               on database: any Database) async throws -> KanbanColumn
    {
        guard let c = try await KanbanColumn.query(on: database)
            .filter(\.$id == columnID).filter(\.$tenantID == tenantID).first()
        else { throw HTTPError(.notFound, message: "column_not_found") }
        return c
    }

    private func requireCard(tenantID: UUID, cardID: UUID) async throws -> KanbanCard {
        try await requireCard(tenantID: tenantID, cardID: cardID, on: db)
    }

    private func requireCard(tenantID: UUID, cardID: UUID,
                             on database: any Database) async throws -> KanbanCard
    {
        guard let c = try await KanbanCard.query(on: database)
            .filter(\.$id == cardID).filter(\.$tenantID == tenantID).first()
        else { throw HTTPError(.notFound, message: "card_not_found") }
        return c
    }

    private func siblingColumn(_ id: UUID?, boardID: UUID,
                               on database: any Database) async throws -> KanbanColumn?
    {
        guard let id else { return nil }
        guard let column = try await KanbanColumn.query(on: database)
            .filter(\.$id == id).filter(\.$boardID == boardID).first()
        else { throw HTTPError(.unprocessableContent, message: "column_neighbor_not_found") }
        return column
    }

    private func siblingCard(_ id: UUID?, columnID: UUID,
                             on database: any Database) async throws -> KanbanCard?
    {
        guard let id else { return nil }
        guard let card = try await KanbanCard.query(on: database)
            .filter(\.$id == id).filter(\.$columnID == columnID).first()
        else { throw HTTPError(.unprocessableContent, message: "card_neighbor_not_found") }
        return card
    }
}
