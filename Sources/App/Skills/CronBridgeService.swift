import Foundation
import Hummingbird
import Logging

/// Bridges LuminaVault to a tenant's **Hermes** cron jobs (the real
/// `hermes cron` ones — Telegram/Discord digests, scrapers — NOT LuminaVault's
/// own `CronScheduler`). Managed transport = `docker exec` into the tenant's
/// container (same seam as `HermesHubSkillsService`). The source of truth is
/// `$HERMES_HOME/cron/jobs.json`; `hermes cron list` has no JSON mode. BYO/
/// standalone transport (no container) is added separately.
struct CronBridgeService {
    let docker: any DockerExec
    let containerManager: HermesContainerManager
    let logger: Logger
    /// HERMES_HOME inside the managed container (see docker-compose).
    private let hermesHome = "/opt/data"

    // MARK: - Managed (docker exec)

    func listManaged(tenantID: UUID) async throws -> [HermesCronJob] {
        let handle = try await requireHandle(tenantID: tenantID)
        let result = try await docker.exec(
            container: handle.containerName,
            command: ["cat", "\(hermesHome)/cron/jobs.json"],
            stdin: nil,
        )
        // Missing file (no jobs yet) → empty list, not an error.
        guard result.ok, let data = result.stdout.data(using: .utf8) else { return [] }
        return Self.parse(data)
    }

    /// Create a Hermes cron job via the CLI inside the container, then return the
    /// refreshed list. `command` is an argv array (no shell), so values are not
    /// shell-interpolated.
    func createManaged(tenantID: UUID, spec: CronCreateSpec) async throws -> [HermesCronJob] {
        let handle = try await requireHandle(tenantID: tenantID)
        var command = ["hermes", "cron", "create", spec.schedule]
        if let prompt = spec.prompt, !prompt.isEmpty { command.append(prompt) }
        if let name = spec.name, !name.isEmpty { command += ["--name", name] }
        if let deliver = spec.deliver, !deliver.isEmpty { command += ["--deliver", deliver] }
        for skill in spec.skills ?? [] where !skill.isEmpty { command += ["--skill", skill] }
        let result = try await docker.exec(container: handle.containerName, command: command, stdin: nil)
        guard result.ok else {
            logger.error("hermes cron create failed tenant=\(tenantID) exit=\(result.exitCode): \(Logger.redact(result.stderr))")
            throw HTTPError(.badGateway, message: "cron_create_failed")
        }
        return try await listManaged(tenantID: tenantID)
    }

    func mutateManaged(tenantID: UUID, action: String, id: String) async throws -> [HermesCronJob] {
        let handle = try await requireHandle(tenantID: tenantID)
        let result = try await docker.exec(
            container: handle.containerName,
            command: ["hermes", "cron", action, id],
            stdin: nil,
        )
        guard result.ok else { throw HTTPError(.badGateway, message: "cron_\(action)_failed") }
        return try await listManaged(tenantID: tenantID)
    }

    private func requireHandle(tenantID: UUID) async throws -> HermesContainerHandle {
        guard let handle = try await containerManager.handle(tenantID: tenantID) else {
            throw HTTPError(.notFound, message: "no_hermes_container")
        }
        return handle
    }

    // MARK: - Parse jobs.json (robust to field shape)

    static func parse(_ data: Data) -> [HermesCronJob] {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let jobs = obj["jobs"] as? [[String: Any]]
        else { return [] }
        return jobs.compactMap { j in
            guard let id = j["id"] as? String else { return nil }
            let lastRun: String?
            if let s = j["last_run"] as? String { lastRun = s }
            else if let d = j["last_run"] as? [String: Any] {
                lastRun = (d["at"] as? String) ?? (d["status"] as? String)
            } else { lastRun = nil }
            let mode = (j["no_agent"] as? Bool == true) ? "script" : "agent"
            return HermesCronJob(
                id: id,
                name: j["name"] as? String,
                schedule: j["schedule"] as? String,
                deliver: j["deliver"] as? String,
                lastRun: lastRun,
                status: (j["status"] as? String) ?? "active",
                mode: mode,
            )
        }
    }
}

/// Structured create spec (filled directly, or by NL → spec via JobIntentClassifier).
struct CronCreateSpec: Decodable {
    let schedule: String
    let prompt: String?
    let name: String?
    let deliver: String?
    let skills: [String]?
}

/// One Hermes cron job (subset surfaced to the app). Server-local for now;
/// promote to LuminaVaultShared when the iOS list lands.
struct HermesCronJob: Codable, ResponseEncodable {
    let id: String
    let name: String?
    let schedule: String?
    let deliver: String?
    let lastRun: String?
    let status: String?
    let mode: String?
}

struct HermesCronListResponse: Codable, ResponseEncodable {
    let source: String   // "managed" | "byo"
    let jobs: [HermesCronJob]
}
