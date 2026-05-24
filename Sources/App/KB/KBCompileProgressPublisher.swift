import Foundation
import Logging
import LuminaVaultShared

/// HER-288 — fan-out of kb-compile progress events to whatever transport
/// the deployment wires up. The default production impl emits to the
/// per-tenant /v1/ws broadcast channel; tests use Noop or a recording
/// publisher.
protocol KBCompileProgressPublisher: Sendable {
    func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async
}

/// Drops every event. Used in unit tests that don't care about WS, and as
/// a safety default when no concrete publisher is wired.
struct NoopKBCompileProgressPublisher: KBCompileProgressPublisher {
    init() {}
    func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async {}
}

/// Encodes the event as JSON text and broadcasts to all of the tenant's
/// open WS connections via `ConnectionManager`. Encode/transport failures
/// are logged at warning level and swallowed — a sick WS path must never
/// break kb-compile.
struct WebSocketKBCompileProgressPublisher: KBCompileProgressPublisher {
    private let connectionManager: ConnectionManager
    private let logger: Logger
    private let encoder: JSONEncoder

    init(connectionManager: ConnectionManager, logger: Logger) {
        self.connectionManager = connectionManager
        self.logger = logger
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async {
        do {
            let data = try encoder.encode(event)
            guard let message = String(data: data, encoding: .utf8) else {
                logger.warning("kb-compile progress encode produced non-utf8 bytes", metadata: [
                    "tenant_id": .string(tenantID.uuidString),
                ])
                return
            }
            await connectionManager.broadcast(tenantID: tenantID.uuidString, message: message)
        } catch {
            logger.warning("kb-compile progress publish failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "error": .string("\(error)"),
            ])
        }
    }
}
