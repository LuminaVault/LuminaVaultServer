import FluentKit
import Foundation
import LuminaVaultShared

/// A thread where the user and several of their agents talk.
final class AgentRoom: Model, TenantModel, @unchecked Sendable {
    static let schema = "agent_rooms"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "title") var title: String
    @Field(key: "token_budget") var tokenBudget: Int
    @Field(key: "spent_tokens") var spentTokens: Int
    @OptionalField(key: "stop_requested_at") var stopRequestedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

/// One agent in a room. `instanceID` is `central` (a LuminaVault persona,
/// `profile` = its slug) or `byo` (the user's own Hermes).
final class AgentRoomMember: Model, @unchecked Sendable {
    static let schema = "agent_room_members"

    @ID(key: .id) var id: UUID?
    @Field(key: "room_id") var roomID: UUID
    @Field(key: "instance_id") var instanceID: String
    @OptionalField(key: "profile") var profile: String?
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    @Field(key: "respond_mode") var respondModeRaw: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    var respondMode: AgentRoomRespondMode {
        get { AgentRoomRespondMode(rawValue: respondModeRaw) ?? .mention }
        set { respondModeRaw = newValue.rawValue }
    }

    init() {}
}

final class AgentRoomMessage: Model, @unchecked Sendable {
    static let schema = "agent_room_messages"

    @ID(key: .id) var id: UUID?
    @Field(key: "room_id") var roomID: UUID
    @Field(key: "author_kind") var authorKindRaw: String
    @OptionalField(key: "member_id") var memberID: UUID?
    @Field(key: "body") var body: String
    @OptionalField(key: "tokens") var tokens: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    var authorKind: AgentRoomAuthorKind {
        get { AgentRoomAuthorKind(rawValue: authorKindRaw) ?? .system }
        set { authorKindRaw = newValue.rawValue }
    }

    init() {}
}
