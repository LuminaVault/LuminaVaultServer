import AsyncHTTPClient
import Foundation
import Logging
import LuminaVaultShared
import NIOCore
import NIOHTTP1

/// The one client for a tenant's Hermes **dashboard** (`hermes_cli/web_server.py`,
/// `/api/*`, sealed dashboard token). Used by `RemoteHermesTransport`, the
/// dashboard capability probe, and `CronBridgeService` BYO calls.
///
/// Security: `SSRFGuard.validate` runs on every call (the URL is user-supplied
/// and DNS can rebind between calls), bodies are capped (8 MiB lists, 2 MiB
/// files), timeouts are 15 s, and the token is never logged. Reads are
/// paced by the caller (`HermesMirrorService` keeps ≤20 rps); a 429 backs off
/// and retries up to three times.
struct HermesDashboardClient: Sendable {
    static let listBodyCap = 8 * 1024 * 1024
    static let fileBodyCap = 2 * 1024 * 1024
    static let timeout: TimeAmount = .seconds(15)
    static let maxRetries = 3

    let baseURL: String
    let token: String
    let ssrfGuard: SSRFGuard
    let http: any HermesHTTPExecuting
    let logger: Logger

    init(
        baseURL: String,
        token: String,
        ssrfGuard: SSRFGuard,
        http: any HermesHTTPExecuting = AsyncHTTPClientHermesHTTP(),
        logger: Logger
    ) {
        self.baseURL = baseURL
        self.token = token
        self.ssrfGuard = ssrfGuard
        self.http = http
        self.logger = logger
    }

    // MARK: - Status / auth probe

    /// `GET /api/status` is the dashboard's public liveness probe — it answers
    /// 200 in both auth modes, so it only tells us reachability, version and
    /// whether the gate is on.
    func status() async throws -> HermesDashboardStatus {
        let response = try await get("/api/status", cap: Self.fileBodyCap)
        guard response.isSuccess, let object = response.jsonObject() else {
            throw HermesMirrorTransportError.http(status: response.status, path: "/api/status")
        }
        let cwd = try? await defaultCwd()
        return HermesDashboardStatus(
            reachable: true,
            authRequired: object["auth_required"] as? Bool,
            version: object["version"] as? String,
            defaultCwd: cwd
        )
    }

    /// Distinguishes the two dashboard auth modes by hitting a protected route.
    /// A login redirect or 401 while `auth_required` is on means the OAuth gate
    /// is active and no bearer path exists (`oauth_only`).
    func probeAuthMode(authRequired: Bool?) async -> HermesDashboardAuthMode {
        do {
            let response = try await get("/api/skills", cap: Self.listBodyCap)
            if response.isSuccess {
                return .bearer
            }
            if response.isRedirect {
                return .oauthOnly
            }
            if response.status == 401 || response.status == 403 {
                return authRequired == true ? .oauthOnly : .unauthorized
            }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    /// `GET /api/fs/default-cwd` → the directory relative fs paths resolve against.
    func defaultCwd() async throws -> String? {
        let response = try await get("/api/fs/default-cwd", cap: Self.fileBodyCap)
        guard response.isSuccess else { return nil }
        let object = response.jsonObject()
        return (object?["cwd"] as? String) ?? (object?["path"] as? String)
    }

    // MARK: - Skills

    func listSkills() async throws -> [HermesMirrorSkill] {
        let response = try await get("/api/skills", cap: Self.listBodyCap)
        try Self.requireSuccess(response, path: "/api/skills")
        guard let rows = response.json() as? [[String: Any]] else {
            throw HermesMirrorTransportError.invalidResponse("/api/skills")
        }
        return rows.compactMap(Self.parseSkill)
    }

    static func parseSkill(_ row: [String: Any]) -> HermesMirrorSkill? {
        guard let name = row["name"] as? String, !name.isEmpty else { return nil }
        let source: HermesMirroredSkillSource = switch (row["provenance"] as? String) ?? "" {
        case "hub": .hub
        case "bundled": .builtin
        default: .custom
        }
        return HermesMirrorSkill(
            name: name,
            description: (row["description"] as? String) ?? "",
            enabled: (row["enabled"] as? Bool) ?? true,
            source: source,
            contentHash: nil
        )
    }

    func skillContent(name: String) async throws -> String {
        let response = try await get("/api/skills/content", query: [("name", name)], cap: Self.fileBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("skill:\(name)")
        }
        try Self.requireSuccess(response, path: "/api/skills/content")
        guard let content = response.jsonObject()?["content"] as? String else {
            throw HermesMirrorTransportError.invalidResponse("/api/skills/content")
        }
        return content
    }

    func toggleSkill(name: String, enabled: Bool) async throws {
        let response = try await send(.PUT, "/api/skills/toggle", json: ["name": .string(name), "enabled": .bool(enabled)], cap: Self.fileBodyCap)
        try Self.requireSuccess(response, path: "/api/skills/toggle")
    }

    func createSkill(name: String, content: String) async throws {
        let response = try await send(.POST, "/api/skills", json: ["name": .string(name), "content": .string(content)], cap: Self.fileBodyCap)
        try Self.requireSuccess(response, path: "/api/skills")
    }

    // MARK: - Cron

    /// Raw `GET /api/cron/jobs` body — `CronBridgeService.parse` and the mirror
    /// both consume it, each with its own shape mapping.
    func listCronJobsRaw() async throws -> Data {
        let response = try await get("/api/cron/jobs", cap: Self.listBodyCap)
        try Self.requireSuccess(response, path: "/api/cron/jobs")
        return response.data
    }

    /// Raw `POST /api/cron/jobs` response body (the created job document).
    func createCronJobRaw(_ body: [String: JSONValue]) async throws -> Data {
        let response = try await send(.POST, "/api/cron/jobs", json: body, cap: Self.fileBodyCap)
        try Self.requireSuccess(response, path: "/api/cron/jobs")
        return response.data
    }

    func listJobs() async throws -> [HermesMirrorJob] {
        try await Self.parseJobs(listCronJobsRaw())
    }

    func createJob(_ spec: HermesMirrorJobSpec) async throws -> HermesMirrorJob {
        let data = try await createCronJobRaw(spec.body)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let job = Self.parseJob(object)
        {
            return job
        }
        // Some Hermes versions answer `{"ok": true}`; re-list and match by name.
        let jobs = try await listJobs()
        guard let created = jobs.first(where: { $0.name == spec.name }) else {
            throw HermesMirrorTransportError.invalidResponse("/api/cron/jobs")
        }
        return created
    }

    /// `PUT /api/cron/jobs/{id}` with `{"updates": {...}}` (`CronJobUpdate`).
    func updateJob(id: String, updates: HermesMirrorJobUpdate) async throws -> HermesMirrorJob {
        let jobID = try HermesJobID.validate(id)
        let response = try await send(.PUT, "/api/cron/jobs/\(jobID)", json: ["updates": .object(updates.updates)], cap: Self.fileBodyCap)
        return try jobResponse(response, path: "/api/cron/jobs/{id}", id: jobID)
    }

    func pauseJob(id: String) async throws -> HermesMirrorJob {
        try await jobAction(id: id, action: "pause")
    }

    func resumeJob(id: String) async throws -> HermesMirrorJob {
        try await jobAction(id: id, action: "resume")
    }

    func triggerJob(id: String) async throws -> HermesMirrorJob {
        try await jobAction(id: id, action: "trigger")
    }

    func deleteJob(id: String) async throws {
        let jobID = try HermesJobID.validate(id)
        let response = try await send(.DELETE, "/api/cron/jobs/\(jobID)", json: nil, cap: Self.fileBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("job:\(jobID)")
        }
        try Self.requireSuccess(response, path: "/api/cron/jobs/{id}")
    }

    private func jobAction(id: String, action: String) async throws -> HermesMirrorJob {
        let jobID = try HermesJobID.validate(id)
        let response = try await send(.POST, "/api/cron/jobs/\(jobID)/\(action)", json: nil, cap: Self.fileBodyCap)
        return try jobResponse(response, path: "/api/cron/jobs/{id}/\(action)", id: jobID)
    }

    private func jobResponse(_ response: HermesHTTPResponse, path: String, id: String) throws -> HermesMirrorJob {
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("job:\(id)")
        }
        if response.status == 400 {
            throw HermesMirrorTransportError.invalidResponse("\(path):rejected")
        }
        try Self.requireSuccess(response, path: path)
        guard let object = response.jsonObject(), let job = Self.parseJob(object) else {
            throw HermesMirrorTransportError.invalidResponse(path)
        }
        return job
    }

    // MARK: - Cron runs

    /// `GET /api/cron/jobs/{id}/runs?limit=` — run sessions (`cron_<job>_<ts>`)
    /// newest first, in the `/api/sessions` row shape
    /// (`web_server.py:_list_cron_job_runs_sync`).
    func jobRuns(jobID: String, limit: Int) async throws -> [HermesMirrorJobRun] {
        let id = try HermesJobID.validate(jobID)
        let bounded = max(1, min(limit, 100))
        let response = try await get("/api/cron/jobs/\(id)/runs", query: [("limit", String(bounded))], cap: Self.listBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("job:\(id)")
        }
        try Self.requireSuccess(response, path: "/api/cron/jobs/{id}/runs")
        return Self.parseRuns(response.json())
    }

    static func parseRuns(_ json: Any?) -> [HermesMirrorJobRun] {
        let rows: [[String: Any]] = if let object = json as? [String: Any] {
            (object["runs"] as? [[String: Any]]) ?? (object["sessions"] as? [[String: Any]]) ?? []
        } else if let list = json as? [[String: Any]] {
            list
        } else {
            []
        }
        return rows.compactMap { row -> HermesMirrorJobRun? in
            guard let key = row["id"] as? String, !key.isEmpty,
                  let started = HermesDates.parse(row["started_at"] ?? row["created_at"])
            else { return nil }
            let ended = HermesDates.parse(row["ended_at"])
            let lastActive = HermesDates.parse(row["last_active"] ?? row["updated_at"])
            let active = (row["is_active"] as? Bool) ?? false
            let status: HermesJobRunStatus = active ? .running : .ok
            return HermesMirrorJobRun(
                key: key,
                status: status,
                startedAt: started,
                finishedAt: active ? nil : (ended ?? lastActive ?? started),
                error: nil,
                tokensIn: (row["input_tokens"] as? NSNumber)?.intValue,
                tokensOut: (row["output_tokens"] as? NSNumber)?.intValue
            )
        }
    }

    /// The run's final assistant message — what Hermes delivered.
    func jobRunOutput(jobID _: String, runKey: String) async throws -> String? {
        let messages = try await sessionMessages(id: runKey)
        return Self.finalAssistantText(messages)
    }

    static func finalAssistantText(_ messages: [HermesMirrorSessionMessage]) -> String? {
        for message in messages.reversed() where message.role == "assistant" {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    static func parseJobs(_ data: Data) -> [HermesMirrorJob] {
        let raw = try? JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let object = raw as? [String: Any], let list = object["jobs"] as? [[String: Any]] {
            rows = list
        } else if let list = raw as? [[String: Any]] {
            rows = list
        } else {
            return []
        }
        return rows.compactMap(parseJob)
    }

    static func parseJob(_ row: [String: Any]) -> HermesMirrorJob? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let schedule: String? = if let display = row["schedule_display"] as? String {
            display
        } else if let object = row["schedule"] as? [String: Any] {
            (object["display"] as? String) ?? (object["expr"] as? String)
        } else {
            row["schedule"] as? String
        }
        let paused = (row["enabled"] as? Bool) == false
            || (row["state"] as? String) == "paused"
            || (row["status"] as? String) == "paused"
        return HermesMirrorJob(
            id: id,
            name: row["name"] as? String,
            schedule: schedule,
            prompt: row["prompt"] as? String,
            paused: paused,
            lastRunAt: HermesDates.parse(row["last_run_at"] ?? row["last_run"]),
            nextRunAt: HermesDates.parse(row["next_run_at"]),
            raw: JSONValue(foundation: row)
        )
    }

    // MARK: - Filesystem

    func listFiles(path: String) async throws -> [HermesMirrorFileEntry] {
        let validated = try HermesMirrorPath.validate(path)
        let response = try await get("/api/fs/list", query: [("path", validated)], cap: Self.listBodyCap)
        try Self.requireSuccess(response, path: "/api/fs/list")
        guard let object = response.jsonObject() else {
            throw HermesMirrorTransportError.invalidResponse("/api/fs/list")
        }
        if let error = object["error"] as? String {
            if error == "ENOENT" || error == "ENOTDIR" {
                throw HermesMirrorTransportError.notFound(validated)
            }
            throw HermesMirrorTransportError.invalidResponse("/api/fs/list:\(error)")
        }
        let entries = (object["entries"] as? [[String: Any]]) ?? []
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String, let entryPath = entry["path"] as? String else { return nil }
            return HermesMirrorFileEntry(name: name, path: entryPath, isDirectory: (entry["isDirectory"] as? Bool) ?? false)
        }
    }

    func readText(path: String) async throws -> String {
        let validated = try HermesMirrorPath.validate(path)
        let response = try await get("/api/fs/read-text", query: [("path", validated)], cap: Self.fileBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound(validated)
        }
        if response.status == 413 {
            throw HermesMirrorTransportError.bodyTooLarge(path: validated, limit: Self.fileBodyCap)
        }
        try Self.requireSuccess(response, path: "/api/fs/read-text")
        guard let object = response.jsonObject(), let text = object["text"] as? String else {
            throw HermesMirrorTransportError.invalidResponse("/api/fs/read-text")
        }
        if (object["binary"] as? Bool) == true {
            throw HermesMirrorTransportError.invalidResponse("binary:\(validated)")
        }
        return text
    }

    func writeText(path: String, content: String) async throws {
        let validated = try HermesMirrorPath.validate(path)
        guard content.utf8.count <= Self.fileBodyCap else {
            throw HermesMirrorTransportError.bodyTooLarge(path: validated, limit: Self.fileBodyCap)
        }
        let response = try await send(.POST, "/api/fs/write-text", json: ["path": .string(validated), "content": .string(content)], cap: Self.fileBodyCap)
        try Self.requireSuccess(response, path: "/api/fs/write-text")
    }

    func mkdir(path: String) async throws {
        let validated = try HermesMirrorPath.validate(path)
        let response = try await send(.POST, "/api/files/mkdir", json: ["path": .string(validated)], cap: Self.fileBodyCap)
        try Self.requireSuccess(response, path: "/api/files/mkdir")
    }

    // MARK: - Sessions

    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage {
        let response = try await get(
            "/api/sessions",
            query: [("limit", String(limit)), ("offset", String(offset)), ("order", "recent"), ("min_messages", "1")],
            cap: Self.listBodyCap
        )
        try Self.requireSuccess(response, path: "/api/sessions")
        return Self.parseSessions(response.json())
    }

    static func parseSessions(_ json: Any?) -> HermesMirrorSessionPage {
        let rows: [[String: Any]]
        var total: Int?
        if let object = json as? [String: Any] {
            rows = (object["sessions"] as? [[String: Any]]) ?? (object["items"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) ?? []
            total = (object["total"] as? NSNumber)?.intValue
        } else if let list = json as? [[String: Any]] {
            rows = list
        } else {
            rows = []
        }
        let sessions = rows.compactMap { row -> HermesMirrorSession? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return HermesMirrorSession(
                id: id,
                title: (row["title"] as? String) ?? (row["display_name"] as? String) ?? (row["preview"] as? String),
                source: row["source"] as? String,
                startedAt: HermesDates.parse(row["started_at"] ?? row["created_at"]),
                lastActiveAt: HermesDates.parse(row["last_active"] ?? row["updated_at"] ?? row["ended_at"]),
                messageCount: (row["message_count"] as? NSNumber)?.intValue ?? 0
            )
        }
        return HermesMirrorSessionPage(sessions: sessions, total: total)
    }

    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage] {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response = try await get("/api/sessions/\(encodedID)/messages", query: [("limit", "500")], cap: Self.listBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("session:\(id)")
        }
        try Self.requireSuccess(response, path: "/api/sessions/{id}/messages")
        return Self.parseMessages(response.json())
    }

    /// `GET /api/sessions/{id}/export` — session metadata + messages as one document.
    func exportSession(id: String) async throws -> Data {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response = try await get("/api/sessions/\(encodedID)/export", cap: Self.listBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("session:\(id)")
        }
        try Self.requireSuccess(response, path: "/api/sessions/{id}/export")
        return response.data
    }

    static func parseMessages(_ json: Any?) -> [HermesMirrorSessionMessage] {
        let rows: [[String: Any]] = if let object = json as? [String: Any] {
            (object["messages"] as? [[String: Any]]) ?? []
        } else if let list = json as? [[String: Any]] {
            list
        } else {
            []
        }
        return rows.compactMap { row in
            guard let role = row["role"] as? String else { return nil }
            let content: String = if let text = row["content"] as? String {
                text
            } else if let parts = row["content"] as? [[String: Any]] {
                parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                ""
            }
            return HermesMirrorSessionMessage(role: role, content: content, timestamp: HermesDates.parse(row["timestamp"]))
        }
    }

    // MARK: - Request plumbing

    private func get(_ path: String, query: [(String, String)] = [], cap: Int) async throws -> HermesHTTPResponse {
        try await send(.GET, path, query: query, json: nil, cap: cap)
    }

    private func send(
        _ method: HTTPMethod,
        _ path: String,
        query: [(String, String)] = [],
        json: [String: JSONValue]?,
        cap: Int
    ) async throws -> HermesHTTPResponse {
        let validated = try await ssrfGuard.validate(rawURL: baseURL)
        var components = URLComponents()
        components.scheme = validated.scheme
        components.host = validated.host
        components.port = validated.port
        var base = validated.path
        while base.hasSuffix("/") {
            base.removeLast()
        }
        components.path = base + path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url?.absoluteString else {
            throw HermesMirrorTransportError.invalidResponse("url")
        }
        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "X-Hermes-Session-Token", value: token)
        request.headers.add(name: "Accept", value: "application/json")
        if let json {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = try .bytes(ByteBuffer(data: JSONEncoder().encode(json)))
        }
        var attempt = 0
        while true {
            attempt += 1
            let response: HermesHTTPResponse
            do {
                response = try await http.execute(request, timeout: Self.timeout, maxBodyBytes: cap)
            } catch let error as HermesMirrorTransportError {
                throw error
            } catch {
                logger.debug("hermes dashboard request failed", metadata: ["path": "\(path)", "error": "\(Logger.redact(String(describing: error)))"])
                throw HermesMirrorTransportError.dashboardUnreachable(path)
            }
            if response.status == 429, attempt < Self.maxRetries {
                let delay = Self.retryDelay(response.headers.first(name: "Retry-After"), attempt: attempt)
                try await Task.sleep(for: delay)
                continue
            }
            return response
        }
    }

    static func retryDelay(_ retryAfter: String?, attempt: Int) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter), seconds > 0 {
            return .seconds(min(seconds, 30))
        }
        return .seconds(Double(attempt))
    }

    private static func requireSuccess(_ response: HermesHTTPResponse, path: String) throws {
        if response.isSuccess {
            return
        }
        if response.isRedirect {
            throw HermesMirrorTransportError.dashboardAuthModeUnsupported
        }
        if response.status == 401 || response.status == 403 {
            throw HermesMirrorTransportError.dashboardUnauthorized
        }
        throw HermesMirrorTransportError.http(status: response.status, path: path)
    }
}
