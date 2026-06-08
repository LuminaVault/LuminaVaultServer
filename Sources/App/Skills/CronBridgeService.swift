import AsyncHTTPClient
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import NIOCore

/// Bridges LuminaVault to a tenant's **Hermes** cron jobs (the real
/// `hermes cron` ones — Telegram/Discord digests, scrapers — NOT LuminaVault's
/// own `CronScheduler`).
///
/// Two transports, picked per tenant:
/// - **Managed:** `docker exec` into the tenant's container (same seam as
///   `HermesHubSkillsService`); reads `$HERMES_HOME/cron/jobs.json`.
/// - **BYO/standalone:** the Hermes dashboard cron API
///   (`<cron_dashboard_url>/api/cron/jobs`, Bearer dashboard token) for a remote
///   Hermes with no container.
struct CronBridgeService {
    let docker: any DockerExec
    let containerManager: HermesContainerManager
    let fluent: Fluent
    let secretBox: SecretBox
    let ssrfGuard: SSRFGuard
    let httpClient: HTTPClient
    let logger: Logger
    /// HERMES_HOME inside the managed container (see docker-compose).
    private let hermesHome = "/opt/data"

    // MARK: - Dispatch (managed → BYO)

    /// List jobs from whichever source the tenant has: a managed container, else
    /// a configured BYO dashboard. The response `source` tells the client which.
    func list(tenantID: UUID) async throws -> HermesCronListResponse {
        if (try? await containerManager.handle(tenantID: tenantID)) ?? nil != nil {
            return HermesCronListResponse(source: "managed", jobs: try await listManaged(tenantID: tenantID))
        }
        if let byo = try await byoConfig(tenantID: tenantID) {
            return HermesCronListResponse(source: "byo", jobs: try await listBYO(baseURL: byo.url, token: byo.token))
        }
        throw HTTPError(.notFound, message: "no_hermes_cron_source")
    }

    // MARK: - BYO (dashboard cron API)

    /// Store (seal) the BYO Hermes dashboard cron endpoint + token. Reuses the
    /// `user_hermes_config` row (empty api_server baseURL is fine — the resolver
    /// treats it as no-override).
    func setBYOConfig(tenantID: UUID, url: String, token: String) async throws {
        let validated = try await ssrfGuard.validate(rawURL: url)
        let sealed = try secretBox.seal(token, tenantID: tenantID)
        let db = fluent.db()
        let row = try await UserHermesConfig.query(on: db, tenantID: tenantID).first() ?? {
            let r = UserHermesConfig()
            r.tenantID = tenantID
            r.baseURL = ""
            return r
        }()
        row.cronDashboardURL = validated.absoluteString
        row.cronDashboardTokenCiphertext = sealed.ciphertext
        row.cronDashboardTokenNonce = sealed.nonce
        try await row.save(on: db)
    }

    private func byoConfig(tenantID: UUID) async throws -> (url: String, token: String)? {
        guard let row = try await UserHermesConfig.query(on: fluent.db(), tenantID: tenantID).first(),
              let url = row.cronDashboardURL, !url.isEmpty,
              let ct = row.cronDashboardTokenCiphertext, let nonce = row.cronDashboardTokenNonce
        else { return nil }
        let token = try secretBox.open(.init(ciphertext: ct, nonce: nonce), tenantID: tenantID)
        return (url, token)
    }

    func listBYO(baseURL: String, token: String) async throws -> [HermesCronJob] {
        // SSRF: the dashboard URL is user-provided — validate (+ re-resolve) it.
        let validated = try await ssrfGuard.validate(rawURL: baseURL)
        let endpoint = validated.absoluteString.hasSuffix("/")
            ? validated.absoluteString + "api/cron/jobs"
            : validated.absoluteString + "/api/cron/jobs"
        var req = HTTPClientRequest(url: endpoint)
        req.headers.add(name: "Authorization", value: "Bearer \(token)")
        req.headers.add(name: "Accept", value: "application/json")
        let resp = try await httpClient.execute(req, timeout: .seconds(15))
        guard (200 ..< 300).contains(Int(resp.status.code)) else {
            throw HTTPError(.badGateway, message: "byo_cron_http_\(resp.status.code)")
        }
        var body = try await resp.body.collect(upTo: 8 * 1024 * 1024)
        let data = body.readData(length: body.readableBytes) ?? Data()
        return Self.parse(data)
    }

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
        let raw = try? JSONSerialization.jsonObject(with: data)
        let jobs: [[String: Any]]
        if let dict = raw as? [String: Any], let arr = dict["jobs"] as? [[String: Any]] {
            jobs = arr                       // jobs.json shape
        } else if let arr = raw as? [[String: Any]] {
            jobs = arr                       // dashboard /api/cron/jobs shape (bare array)
        } else {
            return []
        }
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
