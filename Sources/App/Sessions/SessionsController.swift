import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension SessionListResponse: @retroactive ResponseEncodable {}

/// `GET /v1/sessions` — list chat-history sessions for the OS Shell
/// Sessions tab (HER-245 / HER-259). Joins `conversations` (HER-37)
/// with `conversation_messages` to compute message count + a preview
/// of the most recent turn. `pinned` / `archived` columns aren't on
/// `conversations` yet — defaulted to `false`; HER-261 will add them
/// alongside the workspace binding.
struct SessionsController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> SessionListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let limit = Self.parseLimit(req)
        let workspaceID = Self.parseWorkspaceID(req)

        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }

        struct Row: Decodable {
            let id: UUID
            let title: String
            let updated_at: Date
            let space_id: UUID?
            let message_count: Int
            let last_preview: String?
        }

        // HER-261 — `?workspace=<uuid>` scopes to that Space's conversations.
        // Absent => all workspaces.
        let rows: [Row] = if let workspaceID {
            try await sql.raw("""
            SELECT c.id, c.title, c.updated_at, c.space_id,
                   COALESCE(m.cnt, 0)::int AS message_count,
                   (
                      SELECT content
                      FROM conversation_messages
                      WHERE conversation_id = c.id
                      ORDER BY created_at DESC
                      LIMIT 1
                   ) AS last_preview
            FROM conversations c
            LEFT JOIN (
                SELECT conversation_id, COUNT(*) AS cnt
                FROM conversation_messages
                GROUP BY conversation_id
            ) m ON m.conversation_id = c.id
            WHERE c.tenant_id = \(bind: tenantID)
              AND c.space_id = \(bind: workspaceID)
            ORDER BY c.updated_at DESC
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)
        } else {
            try await sql.raw("""
            SELECT c.id, c.title, c.updated_at, c.space_id,
                   COALESCE(m.cnt, 0)::int AS message_count,
                   (
                      SELECT content
                      FROM conversation_messages
                      WHERE conversation_id = c.id
                      ORDER BY created_at DESC
                      LIMIT 1
                   ) AS last_preview
            FROM conversations c
            LEFT JOIN (
                SELECT conversation_id, COUNT(*) AS cnt
                FROM conversation_messages
                GROUP BY conversation_id
            ) m ON m.conversation_id = c.id
            WHERE c.tenant_id = \(bind: tenantID)
            ORDER BY c.updated_at DESC
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)
        }

        let sessions = rows.map { row in
            SessionDTO(
                id: row.id,
                title: row.title,
                preview: String((row.last_preview ?? "").prefix(140)),
                messageCount: row.message_count,
                lastMessageAt: row.updated_at,
                workspaceID: row.space_id,
                pinned: false,
                archived: false
            )
        }
        return SessionListResponse(sessions: sessions, nextCursor: nil)
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }

    private static func parseWorkspaceID(_ req: Request) -> UUID? {
        guard let raw = req.uri.queryParameters["workspace"] else { return nil }
        return UUID(uuidString: String(raw))
    }
}
