import FluentKit
import Foundation

final class KanbanCard: Model, TenantModel, @unchecked Sendable {
    static let schema = "kanban_cards"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @OptionalField(key: "created_by_user_id") var createdByUserID: UUID?
    @OptionalField(key: "updated_by_user_id") var updatedByUserID: UUID?
    @Field(key: "board_id") var boardID: UUID
    @Field(key: "column_id") var columnID: UUID
    @Field(key: "title") var title: String
    @OptionalField(key: "body") var body: String?
    @Field(key: "rank") var rank: String
    @OptionalField(key: "priority") var priority: String?
    @OptionalField(key: "due_at") var dueAt: Date?
    /// Structured card metadata (M72) — card→Job promotion config. See CardExtra.
    @OptionalField(key: "extra") var extra: CardExtra?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
