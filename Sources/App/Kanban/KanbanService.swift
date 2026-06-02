import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

struct KanbanService: Sendable {
    let fluent: Fluent
    private var db: any Database { fluent.db() }

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
            .sort(\.$createdAt).first() { return existing }
        let b = try await createBoard(tenantID: tenantID, title: "My Board")
        for t in ["Todo", "Doing", "Done"] {
            _ = try await createColumn(tenantID: tenantID, boardID: try b.requireID(), title: t)
        }
        return b
    }

    func patchBoard(tenantID: UUID, boardID: UUID, req: BoardPatchRequest) async throws -> BoardDTO {
        let b = try await requireBoard(tenantID: tenantID, boardID: boardID)
        if let t = req.title { b.title = t }
        if req.archived == true { b.archivedAt = Date() }
        try await bump(b); return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    func deleteBoard(tenantID: UUID, boardID: UUID) async throws {
        let b = try await requireBoard(tenantID: tenantID, boardID: boardID)
        try await b.delete(on: db)
    }

    // MARK: - Columns

    func createColumn(tenantID: UUID, boardID: UUID, title: String) async throws -> KanbanColumn {
        let board = try await requireBoard(tenantID: tenantID, boardID: boardID)
        let last = try await KanbanColumn.query(on: db).filter(\.$boardID == boardID)
            .sort(\.$rank, .descending).first()
        let c = KanbanColumn()
        c.tenantID = tenantID; c.boardID = boardID; c.title = title
        c.rank = RankString.between(last?.rank, nil)
        try await c.save(on: db); try await bump(board); return c
    }

    func patchColumn(tenantID: UUID, boardID: UUID, columnID: UUID, title: String) async throws -> BoardDTO {
        let c = try await requireColumn(tenantID: tenantID, columnID: columnID)
        c.title = title; try await c.save(on: db)
        try await bumpBoard(tenantID: tenantID, boardID: boardID)
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    func deleteColumn(tenantID: UUID, boardID: UUID, columnID: UUID) async throws -> BoardDTO {
        let c = try await requireColumn(tenantID: tenantID, columnID: columnID)
        try await c.delete(on: db)
        try await bumpBoard(tenantID: tenantID, boardID: boardID)
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    func reorderColumn(tenantID: UUID, boardID: UUID, req: ColumnReorderRequest) async throws -> BoardDTO {
        let c = try await requireColumn(tenantID: tenantID, columnID: req.columnID)
        let before: KanbanColumn?
        if let beforeID = req.beforeID {
            before = try await KanbanColumn.find(beforeID, on: db)
        } else {
            before = nil
        }
        let after: KanbanColumn?
        if let afterID = req.afterID {
            after = try await KanbanColumn.find(afterID, on: db)
        } else {
            after = nil
        }
        c.rank = RankString.between(before?.rank, after?.rank)
        try await c.save(on: db)
        try await bumpBoard(tenantID: tenantID, boardID: boardID)
        return try await snapshot(tenantID: tenantID, boardID: boardID)
    }

    // MARK: - Cards

    func createCard(tenantID: UUID, boardID: UUID, columnID: UUID, req: CardCreateRequest) async throws -> KanbanCard {
        _ = try await requireColumn(tenantID: tenantID, columnID: columnID)
        let last = try await KanbanCard.query(on: db).filter(\.$columnID == columnID)
            .sort(\.$rank, .descending).first()
        let card = KanbanCard()
        card.tenantID = tenantID; card.boardID = boardID; card.columnID = columnID
        card.title = req.title; card.body = req.body
        card.priority = req.priority?.rawValue; card.dueAt = req.dueAt
        card.rank = RankString.between(last?.rank, nil)
        try await card.save(on: db); try await bumpBoard(tenantID: tenantID, boardID: boardID)
        return card
    }

    func patchCard(tenantID: UUID, cardID: UUID, req: CardPatchRequest) async throws -> CardDTO {
        let card = try await requireCard(tenantID: tenantID, cardID: cardID)
        if let t = req.title { card.title = t }
        if let b = req.body { card.body = b }
        if let p = req.priority { card.priority = p.rawValue }
        if let d = req.dueAt { card.dueAt = d }
        try await card.save(on: db)
        try await bumpBoard(tenantID: tenantID, boardID: card.boardID)
        return Self.cardDTO(card)
    }

    func deleteCard(tenantID: UUID, cardID: UUID) async throws {
        let card = try await requireCard(tenantID: tenantID, cardID: cardID)
        let boardID = card.boardID
        try await card.delete(on: db)
        try await bumpBoard(tenantID: tenantID, boardID: boardID)
    }

    func moveCard(tenantID: UUID, cardID: UUID, req: CardMoveRequest) async throws -> CardDTO {
        let card = try await requireCard(tenantID: tenantID, cardID: cardID)
        _ = try await requireColumn(tenantID: tenantID, columnID: req.toColumnID)
        let before: KanbanCard?
        if let beforeID = req.beforeID {
            before = try await KanbanCard.find(beforeID, on: db)
        } else {
            before = nil
        }
        let after: KanbanCard?
        if let afterID = req.afterID {
            after = try await KanbanCard.find(afterID, on: db)
        } else {
            after = nil
        }
        card.columnID = req.toColumnID
        card.rank = RankString.between(before?.rank, after?.rank)
        try await card.save(on: db)
        try await bumpBoard(tenantID: tenantID, boardID: card.boardID)
        return Self.cardDTO(card)
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
        return BoardDTO(id: try board.requireID(), title: board.title,
                        version: board.version, columns: colDTOs)
    }

    func version(tenantID: UUID, boardID: UUID) async throws -> Int64 {
        try await requireBoard(tenantID: tenantID, boardID: boardID).version
    }

    // MARK: - Helpers

    private static func cardDTO(_ c: KanbanCard) -> CardDTO {
        let priority: CardPriority?
        if let raw = c.priority {
            priority = CardPriority(rawValue: raw)
        } else {
            priority = nil
        }
        return CardDTO(id: c.id ?? UUID(), columnID: c.columnID, title: c.title, body: c.body,
                       priority: priority,
                       dueAt: c.dueAt, rank: c.rank, updatedAt: c.updatedAt)
    }

    private func requireBoard(tenantID: UUID, boardID: UUID) async throws -> KanbanBoard {
        guard let b = try await KanbanBoard.query(on: db)
            .filter(\.$id == boardID).filter(\.$tenantID == tenantID).first()
        else { throw HTTPError(.notFound, message: "board_not_found") }
        return b
    }

    private func requireColumn(tenantID: UUID, columnID: UUID) async throws -> KanbanColumn {
        guard let c = try await KanbanColumn.query(on: db)
            .filter(\.$id == columnID).filter(\.$tenantID == tenantID).first()
        else { throw HTTPError(.notFound, message: "column_not_found") }
        return c
    }

    private func requireCard(tenantID: UUID, cardID: UUID) async throws -> KanbanCard {
        guard let c = try await KanbanCard.query(on: db)
            .filter(\.$id == cardID).filter(\.$tenantID == tenantID).first()
        else { throw HTTPError(.notFound, message: "card_not_found") }
        return c
    }

    private func bump(_ b: KanbanBoard) async throws { b.version += 1; try await b.save(on: db) }

    private func bumpBoard(tenantID: UUID, boardID: UUID) async throws {
        let b = try await requireBoard(tenantID: tenantID, boardID: boardID); try await bump(b)
    }
}
