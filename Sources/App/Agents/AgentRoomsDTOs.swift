import Foundation
import Hummingbird

// Local copies of the agent-room DTOs. They also live in LuminaVaultShared
// for the next package tag; delete these once the server's Shared pin
// includes them.

/// When an agent in a room speaks without being named.
enum AgentRoomRespondMode: String, Codable, Sendable {
    /// Only when someone writes its `@handle`.
    case mention
    /// On every message the user posts, plus when named.
    case everyHumanMessage = "every_human_message"
}

enum AgentRoomAuthorKind: String, Codable, Sendable {
    case human
    case agent
    /// The room itself: a turn cap reached, a stop, an agent that failed.
    case system
}

struct AgentRoomMemberDTO: Codable, Sendable, Equatable {
    let id: UUID
    let instanceID: String
    /// LuminaVault persona slug for `central`; `nil` for `byo`.
    let profile: String?
    /// Written as `@handle` to hand a turn to this agent.
    let handle: String
    let displayName: String
    let respondMode: AgentRoomRespondMode
}

struct AgentRoomMessageDTO: Codable, Sendable, Equatable {
    let id: UUID
    let authorKind: AgentRoomAuthorKind
    /// Set when `authorKind == .agent`.
    let memberID: UUID?
    let body: String
    let tokens: Int?
    let createdAt: Date?
}

struct AgentRoomDTO: Codable, Sendable, Equatable, ResponseEncodable {
    let id: UUID
    let title: String
    let tokenBudget: Int
    let spentTokens: Int
    let members: [AgentRoomMemberDTO]
    let createdAt: Date?
    let updatedAt: Date?
}

struct AgentRoomsResponse: Codable, Sendable, ResponseEncodable {
    let rooms: [AgentRoomDTO]
}

struct AgentRoomDetailResponse: Codable, Sendable, ResponseEncodable {
    let room: AgentRoomDTO
    /// Oldest first, the most recent 200.
    let messages: [AgentRoomMessageDTO]
}

/// An agent the user can put in a room.
struct AgentRoomCandidateDTO: Codable, Sendable, Equatable {
    let instanceID: String
    let profile: String?
    let displayName: String
    let suggestedHandle: String
}

struct AgentRoomCandidatesResponse: Codable, Sendable, ResponseEncodable {
    let candidates: [AgentRoomCandidateDTO]
}

struct AgentRoomMemberRequest: Codable, Sendable {
    let instanceID: String
    let profile: String?
    /// Defaults to a slug of the display name.
    let handle: String?
    let displayName: String?
    /// Defaults to `.mention`.
    let respondMode: AgentRoomRespondMode?
}

struct AgentRoomCreateRequest: Codable, Sendable {
    let title: String
    let members: [AgentRoomMemberRequest]
}

struct AgentRoomPostRequest: Codable, Sendable {
    let body: String
}

/// One frame on the `POST /rooms/{id}/messages` stream. A `message` frame
/// carries a new row (the user's first, then each agent's); the last frame
/// is `done` with why the chain ended.
struct AgentRoomStreamEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case message
        /// An agent has been asked and is working.
        case thinking
        case done
    }

    let kind: Kind
    let message: AgentRoomMessageDTO?
    let memberID: UUID?
    let reason: AgentRoomChainEnd?
}

enum AgentRoomChainEnd: String, Codable, Sendable {
    /// Nobody left to answer.
    case idle
    /// Hit the per-message agent-turn cap.
    case turnCap = "turn_cap"
    /// The room's token budget is spent.
    case budget
    /// The user pressed Stop.
    case stopped
}
