import Foundation
import Hummingbird

/// Local copies of the inbound-MCP DTOs. They also live in LuminaVaultShared
/// for the next package tag; the server currently depends on a published
/// Shared version that does not include them yet.
enum AgentClientKind: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude_code"
    case codex
    case hermes
    case other
}

struct AgentConnectionDTO: Codable, Sendable, ResponseEncodable {
    let id: UUID
    let name: String
    let clientKind: AgentClientKind
    let tokenPrefix: String
    let createdAt: Date
    let lastUsedAt: Date?
}

struct AgentConnectionIssueRequest: Codable, Sendable {
    let name: String
    let clientKind: AgentClientKind
}

struct AgentConnectionSetupDTO: Codable, Sendable, Equatable, ResponseEncodable {
    let kind: AgentClientKind
    let url: String
    let token: String
    let configLabel: String
    let configLang: String
    let config: String
    let safeLabel: String?
    let safeLang: String?
    let safe: String?
    let export: String?
    let safeNote: String?
    let prompt: String

    init(
        kind: AgentClientKind,
        url: String,
        token: String,
        configLabel: String,
        configLang: String,
        config: String,
        safeLabel: String? = nil,
        safeLang: String? = nil,
        safe: String? = nil,
        export: String? = nil,
        safeNote: String? = nil,
        prompt: String
    ) {
        self.kind = kind
        self.url = url
        self.token = token
        self.configLabel = configLabel
        self.configLang = configLang
        self.config = config
        self.safeLabel = safeLabel
        self.safeLang = safeLang
        self.safe = safe
        self.export = export
        self.safeNote = safeNote
        self.prompt = prompt
    }
}

struct AgentConnectionIssuedResponse: Codable, Sendable, ResponseEncodable {
    let connection: AgentConnectionDTO
    let token: String
    let setup: AgentConnectionSetupDTO
}

struct AgentConnectionsListResponse: Codable, Sendable, ResponseEncodable {
    let connections: [AgentConnectionDTO]
}
