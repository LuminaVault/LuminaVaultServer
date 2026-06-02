import FluentKit
import Foundation

final class KanbanColumn: Model, TenantModel, @unchecked Sendable {
    static let schema = "kanban_columns"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "board_id") var boardID: UUID
    @Field(key: "title") var title: String
    @Field(key: "rank") var rank: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
