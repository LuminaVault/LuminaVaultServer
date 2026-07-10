import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension ChatInboxResponse: @retroactive ResponseEncodable {}
extension ChatPreferencesGetResponse: @retroactive ResponseEncodable {}

/// Task-based chat surface: primary inbox summaries plus cross-device chat
/// preferences. Conversation CRUD remains owned by `ConversationController`.
struct ChatExperienceController {
    let fluent: Fluent
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50

    func addInboxRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("inbox", use: inbox)
    }

    func addPreferencesRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: getPreferences)
        router.put(use: putPreferences)
    }

    // MARK: - GET /v1/chat/inbox

    @Sendable
    func inbox(_ req: Request, ctx: AppRequestContext) async throws -> ChatInboxResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = Self.parseLimit(req)
        let workspaceID = Self.parseWorkspaceID(req)

        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql_unavailable")
        }

        struct Row: Decodable {
            let id: UUID
            let title: String
            let updated_at: Date
            let space_id: UUID?
            let message_count: Int
            let last_preview: String?
        }

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

        let items = rows.map { row in
            ChatInboxItemDTO(
                id: row.id,
                title: row.title,
                preview: String((row.last_preview ?? "").prefix(180)),
                messageCount: row.message_count,
                lastMessageAt: row.updated_at,
                workspaceID: row.space_id,
                sourceLabel: "Lumina",
                providerID: nil,
                model: nil,
                pinned: false,
                archived: false
            )
        }
        return ChatInboxResponse(items: items, nextCursor: nil)
    }

    // MARK: - GET /v1/me/chat-preferences

    @Sendable
    func getPreferences(_: Request, ctx: AppRequestContext) async throws -> ChatPreferencesGetResponse {
        let tenantID = try ctx.requireTenantID()
        guard let row = try await loadPreferences(tenantID: tenantID) else {
            return ChatPreferencesGetResponse()
        }
        return ChatPreferencesGetResponse(preferences: row.toDTO())
    }

    // MARK: - PUT /v1/me/chat-preferences

    @Sendable
    func putPreferences(_ req: Request, ctx: AppRequestContext) async throws -> ChatPreferencesGetResponse {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: ChatPreferencesPutRequest.self, context: ctx)
        let row = try await loadPreferences(tenantID: tenantID) ?? UserChatPreference()
        row.tenantID = tenantID
        row.autoExpandThinking = body.preferences.autoExpandThinking
        row.sendOnReturn = body.preferences.sendOnReturn
        try await row.save(on: fluent.db())
        return ChatPreferencesGetResponse(preferences: row.toDTO())
    }

    private func loadPreferences(tenantID: UUID) async throws -> UserChatPreference? {
        try await UserChatPreference.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
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

private extension UserChatPreference {
    func toDTO() -> ChatPreferencesDTO {
        ChatPreferencesDTO(
            autoExpandThinking: autoExpandThinking,
            sendOnReturn: sendOnReturn
        )
    }
}
