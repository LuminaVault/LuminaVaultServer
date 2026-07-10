import FluentKit
import Foundation

final class Vault: Model, @unchecked Sendable {
    static let schema = "vaults"

    @ID(key: .id) var id: UUID?
    @OptionalField(key: "team_id") var teamID: UUID?
    @OptionalField(key: "personal_owner_user_id") var personalOwnerUserID: UUID?
    @Field(key: "name") var name: String
    @OptionalField(key: "archived_at") var archivedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, teamID: UUID? = nil, personalOwnerUserID: UUID? = nil, name: String) {
        self.id = id
        self.teamID = teamID
        self.personalOwnerUserID = personalOwnerUserID
        self.name = name
    }
}
