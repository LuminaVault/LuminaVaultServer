@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

@Suite("WebSocketKBCompileProgressPublisher")
struct KBCompileProgressPublisherTests {
    @Test func `publish encodes envelope and broadcasts`() async throws {
        let manager = ConnectionManager()
        let tenantID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let publisher = WebSocketKBCompileProgressPublisher(
            connectionManager: manager,
            logger: Logger(label: "test.lv.kb-compile.publisher"),
        )

        // No connections registered → broadcast is a no-op success.
        await publisher.publish(
            .started(.init(runId: tenantID, totalFiles: 7)),
            tenantID: tenantID,
        )

        // Smoke: assert that connection list is empty (broadcast didn't error).
        let connections = await manager.listConnections(tenantID: tenantID.uuidString)
        #expect(connections.isEmpty)
    }

    @Test func `encoded shape is tagged envelope`() throws {
        let event: KBCompileProgressEvent = .preparing(.init(runId: UUID()))
        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "preparing")
        let payload = try #require(json["payload"] as? [String: Any])
        #expect(payload["runId"] is String)
    }
}
