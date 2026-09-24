import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// Muse Chat stage C — the assistant speaking first.
///
/// A skill with a `chat_message` output (the morning brief, a standing job)
/// lands its result in the tenant's Hermie thread as an ordinary assistant
/// message marked `origin = proactive`, then pushes a `chat` notification
/// that deep-links to that thread. Clients render it as the same agent
/// bubble with a caption built from `sourceLabel`.
///
/// The thread is found by `conversations.system_key = 'hermie'` rather than
/// by title, so a user renaming it does not make the next briefing start a
/// second one. It is created on first use.
struct ProactiveChatDelivery {
    /// `conversations.system_key` for the thread proactive messages land in.
    static let hermieSystemKey = "hermie"
    /// Title the thread is created with. The user may rename it.
    static let hermieTitle = "Hermie"
    /// Push payload `deepLink` for a conversation.
    static func deepLink(conversationID: UUID) -> String {
        "luminavault://chat/\(conversationID.uuidString)"
    }

    struct Delivered {
        let conversationID: UUID
        let messageID: UUID
    }

    let fluent: Fluent
    let apns: APNSNotificationService
    let logger: Logger

    /// Appends `content` to the Hermie thread and notifies. The message is
    /// the point: a failed push is logged and does not fail the delivery,
    /// because the message is already in the thread the next time the app
    /// opens.
    @discardableResult
    func deliver(tenantID: UUID, content: String, sourceLabel: String) async throws -> Delivered {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = try await hermieConversation(tenantID: tenantID)
        let conversationID = try conversation.requireID()
        let message = ConversationMessage(
            conversationID: conversationID,
            role: .assistant,
            content: body,
            origin: .proactive,
            sourceLabel: sourceLabel
        )
        try await message.save(on: fluent.db())
        let messageID = try message.requireID()
        // Bump so the thread sorts to the top of the conversation list.
        conversation.updatedAt = Date()
        try await conversation.save(on: fluent.db())

        do {
            try await apns.notify(
                userID: tenantID,
                title: Self.hermieTitle,
                subtitle: sourceLabel,
                body: Self.preview(body),
                category: .chat,
                payload: [
                    "conversationID": conversationID.uuidString,
                    "messageID": messageID.uuidString,
                    "origin": ConversationMessageOrigin.proactive.rawValue,
                    "sourceLabel": sourceLabel,
                    "deepLink": Self.deepLink(conversationID: conversationID),
                ]
            )
        } catch {
            logger.warning("proactive chat push failed tenant=\(tenantID) source=\(sourceLabel): \(error)")
        }
        return Delivered(conversationID: conversationID, messageID: messageID)
    }

    /// The tenant's Hermie thread, created on first use. A concurrent
    /// delivery that loses the insert race on the unique
    /// `(tenant_id, system_key)` index re-reads the winner's row.
    func hermieConversation(tenantID: UUID) async throws -> Conversation {
        if let existing = try await findHermie(tenantID: tenantID) {
            return existing
        }
        let created = Conversation(tenantID: tenantID, title: Self.hermieTitle)
        created.systemKey = Self.hermieSystemKey
        do {
            try await created.save(on: fluent.db())
            return created
        } catch {
            if let winner = try await findHermie(tenantID: tenantID) {
                return winner
            }
            throw error
        }
    }

    private func findHermie(tenantID: UUID) async throws -> Conversation? {
        try await Conversation.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$systemKey == Self.hermieSystemKey)
            .first()
    }

    /// First 140 characters of the first non-empty line with markdown
    /// heading/bullet markers stripped — a lock screen shows plain text.
    static func preview(_ content: String) -> String {
        let line = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> ")) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }
}
