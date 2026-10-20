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
        let delivered = try await append(tenantID: tenantID, body: body, sourceLabel: sourceLabel)
        let conversationID = delivered.conversationID
        let messageID = delivered.messageID

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

    // MARK: - Daily brief (Wave 4)

    static let briefDeepLink = "luminavault://brief"
    static let briefBudgetKind = "brief"
    static let briefActionCategory = "brief"
    static let briefThreadID = "brief"
    static let briefTitle = "Your daily brief"

    /// "Your brief is ready — 4 cards".
    static func briefLine(cardCount: Int) -> String {
        "Your brief is ready — \(cardCount) \(cardCount == 1 ? "card" : "cards")"
    }

    /// Whether the brief's push went out, and if not, why.
    enum BriefPush: String, Equatable {
        case sent
        case optedOut = "opted_out"
        case noDevice = "no_device"
        case budgetSpent = "budget_spent"
    }

    /// The daily brief's chat message: one line linking to the cards
    /// (`luminavault://brief`) instead of the whole text. Its push is
    /// proactive: `passive`, action category `brief`, and it spends the
    /// day's `ProactivePushBudget` slot (shared with the weekly learned
    /// digest). The base category stays `chat`, so the chat opt-out still
    /// gates it. Opted out or no device → the budget is left alone; a slot
    /// already spent today → the message lands, the push does not.
    @discardableResult
    func deliverBrief(tenantID: UUID, cardCount: Int, sourceLabel: String, now: Date = Date()) async throws -> BriefPush {
        let line = Self.briefLine(cardCount: cardCount)
        let delivered = try await append(
            tenantID: tenantID,
            body: "[\(line)](\(Self.briefDeepLink))",
            sourceLabel: sourceLabel
        )
        let db = fluent.db()
        if try await APNSNotificationService.isCategorySuppressed(.chat, tenantID: tenantID, on: db) {
            return .optedOut
        }
        if try await DeviceToken.query(on: db, tenantID: tenantID).count() == 0 {
            return .noDevice
        }
        let timezone = try await User.find(tenantID, on: db)?.timezone ?? "UTC"
        guard try await ProactivePushBudget(fluent: fluent).claim(
            tenantID: tenantID,
            kind: Self.briefBudgetKind,
            timezone: timezone,
            now: now
        ) else {
            logger.info("brief push dropped tenant=\(tenantID): today's proactive push already spent")
            return .budgetSpent
        }
        do {
            try await apns.notify(
                userID: tenantID,
                title: Self.briefTitle,
                subtitle: nil,
                body: line,
                category: .chat,
                payload: [
                    "conversationID": delivered.conversationID.uuidString,
                    "messageID": delivered.messageID.uuidString,
                    "origin": ConversationMessageOrigin.proactive.rawValue,
                    "sourceLabel": sourceLabel,
                    "deepLink": Self.briefDeepLink,
                ],
                interruptionLevel: .passive,
                threadID: Self.briefThreadID,
                actionCategory: Self.briefActionCategory
            )
        } catch {
            logger.warning("brief push failed tenant=\(tenantID): \(error)")
        }
        return .sent
    }

    /// Appends an assistant message marked `proactive` to the Hermie thread
    /// and bumps the thread to the top of the list.
    private func append(tenantID: UUID, body: String, sourceLabel: String) async throws -> Delivered {
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
        conversation.updatedAt = Date()
        try await conversation.save(on: fluent.db())
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
