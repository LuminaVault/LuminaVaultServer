import Foundation
import Logging

/// Drives the interactive `hermes whatsapp` QR-pairing CLI inside a tenant's
/// Hermes container. Mirrors `XaiOAuthBackend`'s shape (long-running streaming
/// `docker exec`) but for WhatsApp's Baileys pairing instead of an OAuth flow.
///
/// Split into a protocol so `WhatsAppPairingService` can be unit-tested against
/// a stub that replays canned stdout lines.
protocol WhatsAppPairingBackend: Sendable {
    /// Spawn `hermes whatsapp` and return the live streaming handle. The
    /// caller consumes `handle.lines` through `WhatsAppPairParser` until the
    /// process exits (linked) or is cancelled (sheet dismissed).
    func startSession(handle: HermesContainerHandle) async throws -> any StreamingExecHandle

    /// Whether a WhatsApp session is already persisted on the tenant's volume.
    func isPaired(handle: HermesContainerHandle) async -> Bool

    /// Delete the persisted WhatsApp session. Returns `true` on success. The
    /// caller restarts the container afterwards so Baileys drops the live
    /// connection.
    func unlink(handle: HermesContainerHandle) async throws -> Bool
}

/// Live implementation that runs the real CLI via `docker exec`.
///
/// `hermes whatsapp` only prints its QR when attached to a TTY, but
/// `docker exec -i` (what `execStreaming` uses) has none. We wrap the command
/// with util-linux `script`, which allocates a pseudo-TTY and still mirrors the
/// session to stdout (`-q` keeps it quiet; the typescript goes to `/dev/null`).
struct LiveWhatsAppPairingBackend: WhatsAppPairingBackend {
    private let docker: any DockerExec
    private let logger: Logger
    /// Inside-container path to the hermes CLI (Python venv install location).
    private let hermesBinaryPath: String
    /// Session directory on the tenant volume. With `HOME=/opt/data` set on the
    /// container, Baileys' `~/.hermes/platforms/whatsapp/session` resolves here.
    /// **Spike-pinned** — adjust to the exact path observed on the VPS.
    private let sessionDir: String

    init(
        docker: any DockerExec,
        logger: Logger,
        hermesBinaryPath: String = "/opt/hermes/.venv/bin/hermes",
        sessionDir: String = "/opt/data/.hermes/platforms/whatsapp/session",
    ) {
        self.docker = docker
        self.logger = logger
        self.hermesBinaryPath = hermesBinaryPath
        self.sessionDir = sessionDir
    }

    func startSession(handle: HermesContainerHandle) async throws -> any StreamingExecHandle {
        let inner = "\(Self.shellQuote(hermesBinaryPath)) whatsapp"
        logger.info("starting whatsapp pairing", metadata: [
            "container": "\(handle.containerName)",
        ])
        return try await docker.execStreaming(
            container: handle.containerName,
            command: ["script", "-q", "-c", inner, "/dev/null"],
        )
    }

    func isPaired(handle: HermesContainerHandle) async -> Bool {
        let result = try? await docker.exec(
            container: handle.containerName,
            command: ["test", "-d", sessionDir],
        )
        return result?.ok ?? false
    }

    func unlink(handle: HermesContainerHandle) async throws -> Bool {
        let result = try await docker.exec(
            container: handle.containerName,
            command: ["rm", "-rf", sessionDir],
        )
        return result.ok
    }

    /// Single-quote a path for safe embedding in `script -c "<cmd>"`.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
