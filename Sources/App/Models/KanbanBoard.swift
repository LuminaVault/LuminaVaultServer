import FluentKit
import Foundation

final class KanbanBoard: Model, TenantModel, @unchecked Sendable {
    static let schema = "kanban_boards"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "title") var title: String
    @Field(key: "version") var version: Int64
    @OptionalField(key: "created_by_user_id") var createdByUserID: UUID?
    @OptionalField(key: "updated_by_user_id") var updatedByUserID: UUID?
    @OptionalField(key: "archived_at") var archivedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
