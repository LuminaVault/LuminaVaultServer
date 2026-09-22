import Foundation
import Hummingbird

// Local copies of the Agents-page DTOs. They also live in LuminaVaultShared
// for the next package tag; the server currently depends on a published
// Shared version that does not include them yet. Delete these once the
// server's Shared pin includes them.

/// Where an agent runs, as the Agents page groups it.
enum AgentInstanceKind: String, Codable, Sendable {
    /// LuminaVault's own agent: the app and web chat.
    case central
    /// The user's own Hermes gateway (a VPS, a Mac, …).
    case byo
}

enum AgentInstanceStatus: String, Codable, Sendable {
    case ok
    /// Reachable, but a Hermes too old to list profiles: one profile's
    /// sessions only.
    case outdated
    case unreachable
}

struct AgentInstanceDTO: Codable, Sendable, Equatable {
    /// Stable id used in every `/v1/agents/instances/{id}` path.
    let id: String
    let kind: AgentInstanceKind
    let name: String
    let status: AgentInstanceStatus
    let hostname: String?
    let version: String?
    /// Profile names on that instance. Empty for `central`.
    let profiles: [String]
    /// Connected chat platforms (telegram, discord, …), when reported.
    let platforms: [String]
}

struct AgentInstancesResponse: Codable, Sendable, ResponseEncodable {
    let instances: [AgentInstanceDTO]
}

struct AgentSessionDTO: Codable, Sendable, Equatable {
    let instanceID: String
    /// Hermes profile the session belongs to; `nil` for `central` and for
    /// Hermes versions that do not report profiles.
    let profile: String?
    let id: String
    let title: String?
    /// Where the conversation happened: `app`, `telegram`, `discord`,
    /// `cron`, `api_server`, …
    let source: String
    let startedAt: Date?
    let lastActiveAt: Date?
    let messageCount: Int?
    /// Open, with activity in the last five minutes.
    let isActive: Bool
    let costUSD: Double?
}

/// An instance that could not be read. The rest of the list still returns.
struct AgentInstanceErrorDTO: Codable, Sendable, Equatable {
    let instanceID: String
    let message: String
}

struct AgentSessionsResponse: Codable, Sendable, ResponseEncodable {
    let sessions: [AgentSessionDTO]
    let errors: [AgentInstanceErrorDTO]
}

struct AgentMessageDTO: Codable, Sendable, Equatable {
    let role: String
    let content: String?
    /// Set on `tool` messages: which tool produced this result.
    let toolName: String?
    /// The raw tool-call list an assistant message made, as JSON text.
    let toolCalls: String?
    let createdAt: Date?
}

struct AgentSessionMessagesResponse: Codable, Sendable, ResponseEncodable {
    let instanceID: String
    let profile: String?
    let sessionID: String
    let messages: [AgentMessageDTO]
}
