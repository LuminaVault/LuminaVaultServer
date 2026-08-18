import FluentKit
import Foundation

/// One inbound MCP agent token. The plaintext token is not a column —
/// see `tokenHash`. A revoked row stays so the settings page can show
/// that a forgotten key was turned off.
final class AgentConnection: Model, TenantModel, @unchecked Sendable {
    static let schema = "agent_connections"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "name") var name: String
    @Field(key: "client_kind") var clientKindRaw: String
    @Field(key: "token_hash") var tokenHash: Data
    @Field(key: "token_prefix") var tokenPrefix: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?

    var clientKind: AgentClientKind {
        get { AgentClientKind(rawValue: clientKindRaw) ?? .other }
        set { clientKindRaw = newValue.rawValue }
    }

    init() {}

    func asDTO() throws -> AgentConnectionDTO {
        let id = try requireID()
        return AgentConnectionDTO(
            id: id,
            name: name,
            clientKind: clientKind,
            tokenPrefix: tokenPrefix,
            createdAt: createdAt ?? Date(),
            lastUsedAt: lastUsedAt
        )
    }
}
