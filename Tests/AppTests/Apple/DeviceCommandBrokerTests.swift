@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// Apple Integration P0b — the device-RPC broker correlation (no DB / WS peer).
/// `broadcast` to a tenant with no live connections is a no-op, so these
/// exercise the request⇄resolve/timeout contract in isolation.
struct DeviceCommandBrokerTests {
    @Test
    func `resolve completes a pending request`() async throws {
        let broker = DeviceCommandBroker(connectionManager: .shared, logger: Logger(label: "test.devicerpc"), timeout: .seconds(5))
        let command = DeviceCommand(kind: .ping)
        async let pending = broker.request(tenantID: UUID(), command: command)
        try await Task.sleep(for: .milliseconds(80)) // let request register its continuation
        await broker.resolve(DeviceCommandResult(id: command.id, ok: true, payload: ["pong": "1"]))
        let result = try await pending
        #expect(result.ok)
        #expect(result.payload?["pong"] == "1")
    }

    @Test
    func `request times out without a result`() async {
        let broker = DeviceCommandBroker(connectionManager: .shared, logger: Logger(label: "test.devicerpc"), timeout: .milliseconds(120))
        await #expect(throws: DeviceCommandError.timeout) {
            _ = try await broker.request(tenantID: UUID(), command: DeviceCommand(kind: .ping))
        }
    }
}
