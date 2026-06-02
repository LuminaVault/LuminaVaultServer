import Foundation
import LuminaVaultShared
import Logging

enum DeviceCommandError: Error, Equatable {
    case timeout
    case encodingFailed
}

/// Apple Integration P0b — correlates a server→device command with its result.
/// `request(...)` delivers a `DeviceCommand` to the tenant's devices over the
/// WebSocket channel and awaits the matching `DeviceCommandResult` (posted back
/// by the app to `POST /v1/devices/command/{id}/result`), with a timeout.
/// Hermes Apple-write/fresh-read tools call `request`; the result endpoint
/// calls `resolve`.
actor DeviceCommandBroker {
    static let shared = DeviceCommandBroker(
        connectionManager: .shared,
        logger: Logger(label: "lv.apple.device-rpc"),
    )

    private var pending: [UUID: CheckedContinuation<DeviceCommandResult, Error>] = [:]
    private let connectionManager: ConnectionManager
    private let logger: Logger
    private let timeout: Duration

    init(connectionManager: ConnectionManager, logger: Logger, timeout: Duration = .seconds(12)) {
        self.connectionManager = connectionManager
        self.logger = logger
        self.timeout = timeout
    }

    func request(tenantID: UUID, command: DeviceCommand) async throws -> DeviceCommandResult {
        let envelope = DeviceCommandEnvelope(command: command)
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8)
        else { throw DeviceCommandError.encodingFailed }

        await connectionManager.broadcast(tenantID: tenantID.uuidString, message: json)
        logger.info("device.command sent tenant=\(tenantID) id=\(command.id) kind=\(command.kind.rawValue)")

        let id = command.id
        let timeout = self.timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            self.pending[id] = cont
        }
    }

    /// Called by the result endpoint when the app posts a command's result.
    func resolve(_ result: DeviceCommandResult) {
        if let cont = pending.removeValue(forKey: result.id) {
            cont.resume(returning: result)
        }
    }

    private func expire(_ id: UUID) {
        if let cont = pending.removeValue(forKey: id) {
            logger.warning("device.command timed out id=\(id)")
            cont.resume(throwing: DeviceCommandError.timeout)
        }
    }
}
