import Foundation
import HummingbirdWebSocket
import Logging

public actor ConnectionManager {
    public static let shared = ConnectionManager()

    public struct Connection: Sendable {
        let id: UUID
        let tenantID: String
        let username: String
        let connectedAt: Date
        let outbound: WebSocketOutboundWriter
    }

    private var connectionsByTenant: [String: [UUID: Connection]] = [:]
    private let logger = Logger(label: "lv.websocket")

    public init() {}

    public func register(
        tenantID: String,
        username: String,
        outbound: WebSocketOutboundWriter
    ) -> UUID {
        let connectionID = UUID()
        let connection = Connection(
            id: connectionID,
            tenantID: tenantID,
            username: username,
            connectedAt: Date(),
            outbound: outbound
        )
        var tenantConnections = connectionsByTenant[tenantID] ?? [:]
        tenantConnections[connectionID] = connection
        connectionsByTenant[tenantID] = tenantConnections
        logger.info("websocket connected", metadata: [
            "tenant_id": .string(tenantID),
            "username": .string(username),
            "connection_id": .string(connectionID.uuidString)
        ])
        return connectionID
    }

    public func remove(tenantID: String, connectionID: UUID) {
        connectionsByTenant[tenantID]?[connectionID] = nil
        if connectionsByTenant[tenantID]?.isEmpty == true {
            connectionsByTenant[tenantID] = nil
        }
        logger.info("websocket disconnected", metadata: [
            "tenant_id": .string(tenantID),
            "connection_id": .string(connectionID.uuidString)
        ])
    }

    public func broadcast(tenantID: String, message: String) async {
        guard let connections = connectionsByTenant[tenantID] else { return }
        for (connectionID, connection) in connections {
            do {
                try await connection.outbound.write(.text(message))
            } catch {
                logger.warning("websocket broadcast failed", metadata: [
                    "tenant_id": .string(tenantID),
                    "connection_id": .string(connectionID.uuidString),
                    "error": .string("\(error)")
                ])
                connectionsByTenant[tenantID]?[connectionID] = nil
            }
        }
    }

    public func listConnections(tenantID: String) -> [Connection] {
        connectionsByTenant[tenantID].map { Array($0.values) } ?? []
    }
}
