import Foundation
import LuminaVaultShared

/// Who is on the other end of an MCP call, for attributing anything a tool
/// writes.
///
/// Attribution rides the free-form provenance fields (`provider`, `model`,
/// `sourceReference`) rather than a new `MemorySourceKindDTO` case: that enum
/// decodes strictly on shipped clients, so a new value would make every memory
/// list containing an agent save fail to decode on an older iOS build.
struct MCPCaller: Sendable {
    /// The account the call acts as.
    let userID: UUID
    /// `nil` for a first-party session JWT.
    let connectionID: UUID?
    let connectionName: String?
    let clientKind: AgentClientKind?

    static let providerPrefix = "mcp"

    /// True for provenance written by `contribution(_:)`, which
    /// `ModelDisclosurePolicy` leaves visible.
    static func isAgentAttribution(_ model: ModelProvenanceDTO) -> Bool {
        model.provider == providerPrefix || model.provider.hasPrefix(providerPrefix + ":")
    }

    static func session(userID: UUID) -> Self {
        .init(userID: userID, connectionID: nil, connectionName: nil, clientKind: nil)
    }

    /// `provider` reads `mcp:<client kind>` and `model` the key's name, which
    /// is what the user typed when they made the key, so "via laptop" is
    /// recognisable to them.
    ///
    /// On create the reference becomes `memories.origin_source_id`, which is
    /// unique per tenant and kind, so each save gets its own suffix after the
    /// connection id. Updates go to `memory_contributions` only and need none.
    func contribution(_ operation: MemoryContributionOperationDTO) -> MemoryContributionInput {
        let reference = connectionID.map { id in
            operation == .create ? "agent_connection:\(id)#\(UUID().uuidString)" : "agent_connection:\(id)"
        }
        return .model(
            operation,
            source: .manual,
            provider: clientKind.map { "\(Self.providerPrefix):\($0.rawValue)" } ?? Self.providerPrefix,
            model: connectionName ?? "session",
            reference: reference
        )
    }
}
