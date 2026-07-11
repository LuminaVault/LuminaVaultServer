import Foundation
import Logging

/// HER-330 — discrete Docker operations for the **central** (shared) Hermes
/// container, used by `HermesUpdateService` to run a blue-green self-update.
///
/// The central container is normally compose-managed, but the app already
/// drives the host Docker daemon for per-tenant containers (`HermesContainerManager`),
/// so the docker socket is available. We recreate the central container via
/// the docker CLI rather than `docker compose` because the app container has
/// no compose project files. The run spec mirrors `HermesContainerManager.dockerRun`.
///
/// All operations are idempotent where it matters (`rm -f`, `pull`).
struct CentralHermesManager {
    struct Config {
        /// Canonical container name the app's chat path talks to.
        let containerName: String
        /// Temp ("green") container name used while validating the new image.
        let tempContainerName: String
        /// Registry image without tag, e.g. `ghcr.io/luminavault/luminavault-hermes`.
        let registryImage: String
        /// Default release channel tag when the update request omits one.
        let defaultChannelTag: String
        let network: String
        /// Host path bind-mounted at `/opt/data` (memory DB, config, auth).
        let volumePath: String
        let port: Int
        let tempPort: Int
        let apiServerKey: String
        let mnemosyneDataDir: String
    }

    /// Probes a running container's OpenAI gateway. Returns `true` on a 200.
    /// Injected so tests can stub health without real HTTP.
    typealias HealthProbe = @Sendable (_ port: Int, _ apiKey: String) async -> Bool

    let docker: any DockerExec
    let config: Config
    let healthProbe: HealthProbe
    let logger: Logger

    func fullRef(tag: String) -> String {
        "\(config.registryImage):\(tag)"
    }

    // MARK: - Inspection

    /// Verifies the docker daemon is reachable (`docker version`).
    func assertDockerReachable() async throws {
        let result = try await docker.run(args: ["version", "--format", "{{.Server.Version}}"])
        guard result.ok else {
            throw HermesUpdateError.dockerUnreachable(result.stderr)
        }
    }

    /// Image reference (`{{.Config.Image}}`) currently configured on the
    /// running central container, or `nil` if the container is absent.
    func currentImageRef() async -> String? {
        guard let result = try? await docker.run(
            args: ["inspect", "--format", "{{.Config.Image}}", config.containerName]
        ), result.ok else { return nil }
        let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.isEmpty ? nil : ref
    }

    /// Resolved image content digest (`{{.Image}}`) of the running central
    /// container — the immutable sha that survives tag re-pointing.
    func currentImageDigest() async -> String? {
        guard let result = try? await docker.run(
            args: ["inspect", "--format", "{{.Image}}", config.containerName]
        ), result.ok else { return nil }
        let digest = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return digest.isEmpty ? nil : digest
    }

    /// Digest of a local **image** ref (after pull), via `{{.Id}}`.
    func imageDigest(ref: String) async -> String? {
        guard let result = try? await docker.run(
            args: ["image", "inspect", "--format", "{{.Id}}", ref]
        ), result.ok else { return nil }
        let digest = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return digest.isEmpty ? nil : digest
    }

    // MARK: - Update primitives

    /// `docker pull <ref>`. Throws with stderr on non-zero exit.
    func pull(ref: String) async throws {
        let result = try await docker.run(args: ["pull", ref])
        guard result.ok else {
            throw HermesUpdateError.pullFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    /// Launch the new image on the temp name + temp port. The old (canonical)
    /// container keeps running and serving traffic — zero downtime so far.
    func runTemp(image: String) async throws {
        _ = try? await docker.run(args: ["rm", "-f", config.tempContainerName])
        let result = try await docker.run(args: runArgs(
            name: config.tempContainerName,
            port: config.tempPort,
            image: image
        ))
        guard result.ok else {
            throw HermesUpdateError.containerRunFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    /// Poll the temp container's gateway until healthy or `timeout` elapses.
    func awaitTempHealthy(timeoutSeconds: Int, intervalSeconds: Int = 2) async -> Bool {
        await awaitHealthy(port: config.tempPort, timeoutSeconds: timeoutSeconds, intervalSeconds: intervalSeconds)
    }

    /// Poll the canonical container's gateway until healthy.
    func awaitCanonicalHealthy(timeoutSeconds: Int, intervalSeconds: Int = 2) async -> Bool {
        await awaitHealthy(port: config.port, timeoutSeconds: timeoutSeconds, intervalSeconds: intervalSeconds)
    }

    private func awaitHealthy(port: Int, timeoutSeconds: Int, intervalSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await healthProbe(port, config.apiServerKey) {
                return true
            }
            try? await Task.sleep(for: .seconds(intervalSeconds))
        }
        return false
    }

    /// Cutover: remove the validated temp container, stop+remove the old
    /// canonical container, then launch the new image on the canonical
    /// name + port. The `/opt/data` volume is untouched, so memory/auth
    /// persist. Returns once the new canonical container has been launched
    /// (caller health-checks).
    func promoteTempToCanonical(image: String) async throws {
        _ = try? await docker.run(args: ["rm", "-f", config.tempContainerName])
        _ = try? await docker.run(args: ["rm", "-f", config.containerName])
        let result = try await docker.run(args: runArgs(
            name: config.containerName,
            port: config.port,
            image: image
        ))
        guard result.ok else {
            throw HermesUpdateError.containerRunFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    /// Best-effort cleanup of the temp container (failed validation path
    /// where the old canonical container was never touched).
    func removeTemp() async {
        _ = try? await docker.run(args: ["rm", "-f", config.tempContainerName])
    }

    /// Restore the canonical container from a known image ref (rollback).
    /// Removes whatever is currently on the canonical name first.
    func restoreCanonical(image: String) async throws {
        _ = try? await docker.run(args: ["rm", "-f", config.containerName])
        let result = try await docker.run(args: runArgs(
            name: config.containerName,
            port: config.port,
            image: image
        ))
        guard result.ok else {
            throw HermesUpdateError.containerRunFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    // MARK: - Private

    private func runArgs(name: String, port: Int, image: String) -> [String] {
        [
            "run",
            "--detach",
            "--restart=unless-stopped",
            "--name", name,
            "--network", config.network,
            "--publish", "\(port):8642",
            "--volume", "\(config.volumePath):/opt/data",
            "--env", "API_SERVER_ENABLED=true",
            "--env", "API_SERVER_HOST=0.0.0.0",
            "--env", "API_SERVER_PORT=8642",
            "--env", "API_SERVER_KEY=\(config.apiServerKey)",
            "--env", "HERMES_HOME=/opt/data",
            "--env", "MNEMOSYNE_DATA_DIR=\(config.mnemosyneDataDir)",
            image,
            "gateway", "run",
        ]
    }
}

/// Errors surfaced by the central update path. Mapped to step `detail`
/// strings and the job `errorMessage`.
enum HermesUpdateError: Error, Equatable {
    case dockerUnreachable(String)
    case pullFailed(stderr: String, exitCode: Int32)
    case containerRunFailed(stderr: String, exitCode: Int32)
    case healthCheckTimedOut
    case alreadyRunning
    case rollbackFailed(String)
    case perTenantDisabled
}
