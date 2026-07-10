import FluentKit
import Foundation

final class Team: Model, @unchecked Sendable {
    static let schema = "teams"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "owner_user_id") var ownerUserID: UUID
    @Field(key: "billing_sponsor_user_id") var billingSponsorUserID: UUID
    @OptionalField(key: "archived_at") var archivedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, ownerUserID: UUID) {
        self.id = id
        self.name = name
        self.ownerUserID = ownerUserID
        billingSponsorUserID = ownerUserID
    }
}
