import Foundation

/// HER-43 (Slice 1) — boot-time map of catalog `binding` keys to their
/// `PluginConnector` implementation, mirroring `EmbeddingProviderRegistry`.
/// `PluginService` resolves a connector here when running an install's sync.
struct ConnectorRegistry {
    private let byBinding: [String: any PluginConnector]

    init(connectors: [any PluginConnector]) {
        var map: [String: any PluginConnector] = [:]
        for connector in connectors {
            map[connector.binding] = connector
        }
        byBinding = map
    }

    func connector(binding: String) -> (any PluginConnector)? {
        byBinding[binding]
    }
}
