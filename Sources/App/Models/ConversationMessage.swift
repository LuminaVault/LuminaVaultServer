import FluentKit
import Foundation
import LuminaVaultShared

/// HER-37 — single persisted turn within a `Conversation`. `role` mirrors
/// the OpenAI-style string ("user" | "assistant" | "system");
/// `sourceMemoryIDs` is empty for non-assistant turns. The
/// `(conversation_id, created_at)` index in M45 backs ordered transcript
/// loads.
final class ConversationMessage: Model, @unchecked Sendable {
    static let schema = "conversation_messages"

    @ID(key: .id) var id: UUID?
    @Field(key: "conversation_id") var conversationID: UUID
    @Field(key: "role") var role: String
    @Field(key: "content") var content: String
    @Field(key: "source_memory_ids") var sourceMemoryIDs: [UUID]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {
        sourceMemoryIDs = []
    }

    init(
        id: UUID? = nil,
        conversationID: UUID,
        role: ConversationMessageRole,
        content: String,
        sourceMemoryIDs: [UUID] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role.rawValue
        self.content = content
        self.sourceMemoryIDs = sourceMemoryIDs
    }

    /// Convert to the wire DTO. Defaults `role` to `.user` if the row
    /// somehow contains an unknown string — defensive only; the API
    /// layer rejects unknown roles before insert.
    func toDTO() throws -> ConversationMessageDTO {
        try ConversationMessageDTO(
            id: requireID(),
            conversationId: conversationID,
            role: ConversationMessageRole(rawValue: role) ?? .user,
            content: content,
            sourceMemoryIDs: sourceMemoryIDs,
            createdAt: createdAt ?? Date()
        )
    }
}
