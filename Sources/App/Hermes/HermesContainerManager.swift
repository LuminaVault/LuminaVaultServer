import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-240a — lifecycle manager for per-tenant Hermes containers.
///
/// Responsibilities:
///   * Lazily spawn a tenant's container on first call to `ensureRunning`.
///   * Persist a `HermesTenantContainer` row so the (container_name, port,
///     API_SERVER_KEY) tuple survives restarts. The xai-oauth tokens live
///     inside `/opt/data` on the volume bound to that container, so reusing
///     the same name + volume preserves the user's auth.json.
///   * Reap idle containers via `evictIdle()` (called periodically by a
///     background service in `App+build`). Containers with an active
///     xai-oauth token are never evicted.
///
/// Concurrency: actor isolation serialises all writes to docker + DB so two
/// concurrent requests for the same tenant don't race to spawn duplicate
/// containers or allocate the same port.
actor HermesContainerManager {
    struct Config: Sendable {
        let image: String
        let network: String
        let dataRootBase: String
        let portRangeStart: Int
        let portRangeEnd: Int
        let idleTTLSeconds: Int
        init(
            image: String,
            network: String,
            dataRootBase: String,
            portRangeStart: Int,
            portRangeEnd: Int,
            idleTTLSeconds: Int,
        ) {
            self.image = image
            self.network = network
            self.dataRootBase = dataRootBase
            self.portRangeStart = portRangeStart
            self.portRangeEnd = portRangeEnd
            self.idleTTLSeconds = idleTTLSeconds
        }
    }

    enum Error: Swift.Error, Equatable {
        case portRangeExhausted
        case dockerRunFailed(stderr: String, exitCode: Int32)
        case dockerNotRunning(container: String)
    }

    private let docker: any DockerExec
    private let fluent: Fluent
    private let secretBox: SecretBox
    private let config: Config
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        docker: any DockerExec,
        fluent: Fluent,
        secretBox: SecretBox,
        config: Config,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.docker = docker
        self.fluent = fluent
        self.secretBox = secretBox
        self.config = config
        self.logger = logger
        self.now = now
    }

    /// Returns a handle to the tenant's running container. Spawns the
    /// container if it isn't running. Bumps `last_used_at`.
    @discardableResult
    func ensureRunning(tenantID: UUID) async throws -> HermesContainerHandle {
        try await docker.ensureNetworkExists(config.network)

        let existing = try await loadRow(tenantID: tenantID)
        if let row = existing {
            let isUp = (try? await docker.isRunning(container: row.containerName)) ?? false
            if !isUp {
                try await dockerRun(
                    containerName: row.containerName,
                    port: row.port,
                    apiServerKey: try decrypt(row: row, tenantID: tenantID),
                    tenantID: tenantID,
                )
            }
            row.lastUsedAt = now()
            try await row.update(on: fluent.db())
            return try handle(from: row, tenantID: tenantID)
        }

        // First-time spawn.
        let port = try await allocatePort()
        let apiServerKey = randomAPIKey()
        let sealed = try secretBox.seal(apiServerKey, tenantID: tenantID)
        let containerName = "hermes-tenant-\(tenantID.uuidString.lowercased())"
        let row = HermesTenantContainer(
            tenantID: tenantID,
            containerName: containerName,
            port: port,
            apiServerKeyCiphertext: sealed.ciphertext,
            apiServerKeyNonce: sealed.nonce,
            xaiConnectedAt: nil,
            lastUsedAt: now(),
        )
        try await row.create(on: fluent.db())
        do {
            try await dockerRun(
                containerName: containerName,
                port: port,
                apiServerKey: apiServerKey,
                tenantID: tenantID,
            )
        } catch {
            // Roll back the row so a re-call retries cleanly.
            try? await row.delete(on: fluent.db())
            throw error
        }
        logger.info("spawned hermes-tenant container", metadata: [
            "tenantID": "\(tenantID)",
            "container": "\(containerName)",
            "port": "\(port)",
        ])
        return HermesContainerHandle(
            tenantID: tenantID,
            containerName: containerName,
            port: port,
            apiServerKey: apiServerKey,
            xaiConnectedAt: nil,
        )
    }

    /// Returns the handle if one exists in the DB, without spawning. Does
    /// not bump `last_used_at`. Used by status reads.
    func handle(tenantID: UUID) async throws -> HermesContainerHandle? {
        guard let row = try await loadRow(tenantID: tenantID) else { return nil }
        return try handle(from: row, tenantID: tenantID)
    }

    /// Marks the tenant's container as having a live xai-oauth session.
    /// Idempotent — overwrites whatever was there.
    func recordXaiConnected(tenantID: UUID, at: Date) async throws {
        guard let row = try await loadRow(tenantID: tenantID) else { return }
        row.xaiConnectedAt = at
        row.lastUsedAt = at
        try await row.update(on: fluent.db())
    }

    /// Clears the xai-oauth connect marker (after a revoke). Container
    /// becomes eligible for idle eviction.
    func recordXaiDisconnected(tenantID: UUID) async throws {
        guard let row = try await loadRow(tenantID: tenantID) else { return }
        row.xaiConnectedAt = nil
        try await row.update(on: fluent.db())
    }

    /// Stops + removes containers whose `last_used_at` is older than the
    /// idle TTL AND that have no xai-oauth token. Returns the number of
    /// containers evicted.
    @discardableResult
    func evictIdle() async throws -> Int {
        let cutoff = now().addingTimeInterval(-TimeInterval(config.idleTTLSeconds))
        let stale = try await HermesTenantContainer.query(on: fluent.db())
            .filter(\.$xaiConnectedAt == nil)
            .filter(\.$lastUsedAt, .lessThan, cutoff)
            .all()
        for row in stale {
            // `docker rm -f` is idempotent if the container is already gone.
            _ = try? await docker.run(args: ["rm", "-f", row.containerName])
            try await row.delete(on: fluent.db())
            logger.info("evicted idle hermes-tenant container", metadata: [
                "tenantID": "\(row.tenantID)",
                "container": "\(row.containerName)",
            ])
        }
        return stale.count
    }

    // MARK: - Private

    private func loadRow(tenantID: UUID) async throws -> HermesTenantContainer? {
        try await HermesTenantContainer.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
    }

    private func handle(from row: HermesTenantContainer, tenantID: UUID) throws -> HermesContainerHandle {
        let key = try decrypt(row: row, tenantID: tenantID)
        return HermesContainerHandle(
            tenantID: tenantID,
            containerName: row.containerName,
            port: row.port,
            apiServerKey: key,
            xaiConnectedAt: row.xaiConnectedAt,
        )
    }

    private func decrypt(row: HermesTenantContainer, tenantID: UUID) throws -> String {
        try secretBox.open(
            SecretBox.Sealed(
                ciphertext: row.apiServerKeyCiphertext,
                nonce: row.apiServerKeyNonce,
            ),
            tenantID: tenantID,
        )
    }

    private func allocatePort() async throws -> Int {
        let rows = try await HermesTenantContainer.query(on: fluent.db()).all()
        let taken = Set(rows.map(\.port))
        for port in config.portRangeStart..<config.portRangeEnd where !taken.contains(port) {
            return port
        }
        throw Error.portRangeExhausted
    }

    private func randomAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: .min ... .max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func dockerRun(
        containerName: String,
        port: Int,
        apiServerKey: String,
        tenantID: UUID,
    ) async throws {
        let volumePath = "\(config.dataRootBase)/\(tenantID.uuidString.lowercased())"
        let args = [
            "run",
            "--detach",
            "--restart=unless-stopped",
            "--name", containerName,
            "--network", config.network,
            "--publish", "\(port):8642",
            "--volume", "\(volumePath):/opt/data",
            "--env", "API_SERVER_ENABLED=true",
            "--env", "API_SERVER_HOST=0.0.0.0",
            "--env", "API_SERVER_PORT=8642",
            "--env", "API_SERVER_KEY=\(apiServerKey)",
            "--env", "HERMES_HOME=/opt/data",
            config.image,
            "gateway", "run",
        ]
        let result = try await docker.run(args: args)
        guard result.ok else {
            // "already in use" → container exists but stopped; try start.
            if result.stderr.contains("is already in use") {
                let start = try await docker.run(args: ["start", containerName])
                if start.ok { return }
            }
            throw Error.dockerRunFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }
}
