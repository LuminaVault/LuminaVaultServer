import FluentKit
import Foundation

final class TeamMembership: Model, @unchecked Sendable {
    static let schema = "team_memberships"

    @ID(key: .id) var id: UUID?
    @Field(key: "team_id") var teamID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "role") var role: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(teamID: UUID, userID: UUID, role: String) {
        self.teamID = teamID
        self.userID = userID
        self.role = role
    }
}
