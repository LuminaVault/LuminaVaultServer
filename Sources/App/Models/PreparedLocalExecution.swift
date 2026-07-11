import FluentKit
import Foundation
import LuminaVaultShared

final class PreparedLocalExecution: Model, TenantModel, @unchecked Sendable {
    static let schema = "prepared_local_executions"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "conversation_id") var conversationID: UUID
    @OptionalField(key: "user_message_id") var userMessageID: UUID?
    @Field(key: "messages") var messages: [ChatMessage]
    @Field(key: "source_ids") var sourceIDs: [UUID]
    @OptionalField(key: "committed_message_id") var committedMessageID: UUID?
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {
        messages = []
        sourceIDs = []
        expiresAt = .distantPast
    }

    init(id: UUID = UUID(), tenantID: UUID, conversationID: UUID, userMessageID: UUID, messages: [ChatMessage], sourceIDs: [UUID], expiresAt: Date) {
        self.id = id
        self.tenantID = tenantID
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.messages = messages
        self.sourceIDs = sourceIDs
        self.expiresAt = expiresAt
    }
}
