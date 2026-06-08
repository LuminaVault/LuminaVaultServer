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
    /// NL → cron spec (reuses the chat→job classifier).
    let classifier: JobIntentClassifier
    let logger: Logger
    /// HERMES_HOME inside the managed container (see docker-compose).
    private let hermesHome = "/opt/data"

    // MARK: - Create (dispatch + NL preview)

    /// Create a job on whichever source the tenant has (managed exec / BYO API).
    func create(tenantID: UUID, spec: CronCreateSpec) async throws -> HermesCronListResponse {
        if await (try? containerManager.handle(tenantID: tenantID)) ?? nil != nil {
            return try await HermesCronListResponse(source: "managed", jobs: createManaged(tenantID: tenantID, spec: spec))
        }
        if let byo = try await byoConfig(tenantID: tenantID) {
            return try await HermesCronListResponse(source: "byo", jobs: createBYO(baseURL: byo.url, token: byo.token, spec: spec))
        }
        throw HTTPError(.notFound, message: "no_hermes_cron_source")
    }

    /// Natural language → a structured cron spec for confirmation (no write).
    ///
    /// Primary path is a **deterministic** schedule parser: the managed transport
    /// routes through the user's full Hermes *agent* (SOUL + memory + cron tools),
    /// which answers conversationally and ignores a "JSON only" system prompt — so
    /// `JobIntentClassifier` can't be trusted here. The LLM is a fallback only.
    func preview(tenantID: UUID, text: String) async -> CronCreateSpec? {
        let lower = text.lowercased()
        let deliver = lower.contains("telegram") ? "telegram"
            : lower.contains("discord") ? "discord"
            : lower.contains("slack") ? "slack"
            : lower.contains("signal") ? "signal"
            : lower.contains("email") || lower.contains("e-mail") ? "email"
            : "origin"

        if let parsed = Self.parseSchedule(text) {
            return CronCreateSpec(
                schedule: parsed.cron,
                prompt: text,
                name: Self.deriveName(text),
                deliver: deliver,
                skills: nil,
            )
        }

        // Fallback: ask the LLM (works for BYO/plain models that obey JSON).
        let proposal = await classifier.classify(text: text, tenantID: tenantID)
        logger.info("cron preview LLM-fallback isJob=\(proposal.isJob) cron=\(proposal.cron ?? "nil")")
        guard proposal.isJob, let cron = proposal.cron, !cron.isEmpty else { return nil }
        return CronCreateSpec(
            schedule: cron,
            prompt: proposal.spec ?? text,
            name: proposal.title ?? Self.deriveName(text),
            deliver: deliver,
            skills: nil,
        )
    }

    // MARK: - Deterministic NL → cron

    /// Parse common English schedule phrasings into a 5-field crontab. Returns
    /// nil if no recurring schedule is recognizable (caller falls back to the LLM).
    static func parseSchedule(_ text: String) -> (cron: String, human: String)? {
        let lower = text.lowercased()

        // "every N minutes" / "every N hours"
        if let m = firstMatch(#"every\s+(\d{1,3})\s*min"#, in: lower), let n = Int(m[1]), n > 0 {
            return ("*/\(n) * * * *", "Every \(n) minute\(n == 1 ? "" : "s")")
        }
        if let m = firstMatch(#"every\s+(\d{1,3})\s*hour"#, in: lower), let n = Int(m[1]), n > 0 {
            return ("0 */\(n) * * *", "Every \(n) hour\(n == 1 ? "" : "s")")
        }
        if lower.contains("hourly") || lower.range(of: #"every\s+hour"#, options: .regularExpression) != nil {
            return ("0 * * * *", "Every hour")
        }

        let time = parseTimeOfDay(lower) ?? (hour: 9, minute: 0) // sensible default
        let hhmm = "\(time.minute) \(time.hour)"
        let humanTime = formatHuman(hour: time.hour, minute: time.minute)

        // Day-of-week selector
        let dowNames: [(String, Int, String)] = [
            ("monday", 1, "Monday"), ("tuesday", 2, "Tuesday"), ("wednesday", 3, "Wednesday"),
            ("thursday", 4, "Thursday"), ("friday", 5, "Friday"), ("saturday", 6, "Saturday"),
            ("sunday", 0, "Sunday"),
        ]

        if lower.contains("weekday") {
            return ("\(hhmm) * * 1-5", "Every weekday at \(humanTime)")
        }
        if lower.contains("weekend") {
            return ("\(hhmm) * * 0,6", "Every weekend at \(humanTime)")
        }
        for (needle, dow, label) in dowNames where lower.contains(needle) {
            return ("\(hhmm) * * \(dow)", "Every \(label) at \(humanTime)")
        }
        if lower.contains("weekly") || lower.contains("each week") || lower.contains("every week") {
            return ("\(hhmm) * * 1", "Every Monday at \(humanTime)")
        }
        if lower.contains("daily") || lower.contains("every day") || lower.contains("each day")
            || lower.contains("every morning") || lower.contains("every evening")
            || lower.contains("every night") || lower.contains("each morning")
        {
            return ("\(hhmm) * * *", "Every day at \(humanTime)")
        }

        // A bare time with no frequency → assume daily; otherwise unrecognized.
        if parseTimeOfDay(lower) != nil {
            return ("\(hhmm) * * *", "Every day at \(humanTime)")
        }
        return nil
    }

    /// Extract an hour/minute from "9am", "9:30 pm", "at 17:00", "at 8".
    static func parseTimeOfDay(_ lower: String) -> (hour: Int, minute: Int)? {
        // With meridiem (am/pm) — most explicit.
        if let m = firstMatch(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#, in: lower),
           var h = Int(m[1]), (0 ... 23).contains(h)
        {
            let min = m.count > 2 ? (Int(m[2]) ?? 0) : 0
            let mer = m.last ?? ""
            if mer == "pm", h < 12 { h += 12 }
            if mer == "am", h == 12 { h = 0 }
            return (h % 24, min)
        }
        // 24h "at HH:MM" or "at HH".
        if let m = firstMatch(#"at\s+(\d{1,2})(?::(\d{2}))?"#, in: lower),
           let h = Int(m[1]), (0 ... 23).contains(h)
        {
            let min = m.count > 2 ? (Int(m[2]) ?? 0) : 0
            return (h, min)
        }
        return nil
    }

    /// Regex helper → capture groups of the first match (group 0 omitted).
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 1 ..< m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    private static func formatHuman(hour: Int, minute: Int) -> String {
        let mer = hour < 12 ? "AM" : "PM"
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(h12):00 \(mer)" : String(format: "%d:%02d %@", h12, minute, mer)
    }

    /// Short job name from the request text (schedule words trimmed).
    static func deriveName(_ text: String) -> String {
        let stops = ["every", "each", "daily", "weekly", "hourly", "weekday", "weekdays",
                     "weekend", "weekends", "morning", "evening", "night", "at", "am", "pm",
                     "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stops.contains($0) && Int($0) == nil }
        let picked = Array(words.prefix(6)).joined(separator: " ")
        let title = picked.isEmpty ? "Scheduled job" : picked
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    func createBYO(baseURL: String, token: String, spec: CronCreateSpec) async throws -> [HermesCronJob] {
        let validated = try await ssrfGuard.validate(rawURL: baseURL)
        let endpoint = validated.absoluteString.hasSuffix("/")
            ? validated.absoluteString + "api/cron/jobs"
            : validated.absoluteString + "/api/cron/jobs"
        var req = HTTPClientRequest(url: endpoint)
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(token)")
        req.headers.add(name: "Content-Type", value: "application/json")
        var bodyObj: [String: Any] = ["schedule": spec.schedule, "deliver": spec.deliver ?? "origin"]
        if let prompt = spec.prompt, !prompt.isEmpty { bodyObj["prompt"] = prompt }
        if let name = spec.name, !name.isEmpty { bodyObj["name"] = name }
        req.body = try .bytes(JSONSerialization.data(withJSONObject: bodyObj))
        let resp = try await httpClient.execute(req, timeout: .seconds(25))
        guard (200 ..< 300).contains(Int(resp.status.code)) else {
            throw HTTPError(.badGateway, message: "byo_cron_create_\(resp.status.code)")
        }
        return try await listBYO(baseURL: baseURL, token: token)
    }

    // MARK: - Dispatch (managed → BYO)

    /// List jobs from whichever source the tenant has: a managed container, else
    /// a configured BYO dashboard. The response `source` tells the client which.
    func list(tenantID: UUID) async throws -> HermesCronListResponse {
        if await (try? containerManager.handle(tenantID: tenantID)) ?? nil != nil {
            return try await HermesCronListResponse(source: "managed", jobs: listManaged(tenantID: tenantID))
        }
        if let byo = try await byoConfig(tenantID: tenantID) {
            return try await HermesCronListResponse(source: "byo", jobs: listBYO(baseURL: byo.url, token: byo.token))
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
        for skill in spec.skills ?? [] where !skill.isEmpty {
            command += ["--skill", skill]
        }
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
            jobs = arr // jobs.json shape
        } else if let arr = raw as? [[String: Any]] {
            jobs = arr // dashboard /api/cron/jobs shape (bare array)
        } else {
            return []
        }
        return jobs.compactMap { j in
            guard let id = j["id"] as? String else { return nil }
            // schedule: dashboard sends `schedule_display` + an object
            // `schedule {kind,expr,display}`; jobs.json may send a plain string.
            let schedule: String? = if let sd = j["schedule_display"] as? String { sd }
            else if let so = j["schedule"] as? [String: Any] {
                (so["display"] as? String) ?? (so["expr"] as? String)
            } else { j["schedule"] as? String }
            // last run: `last_run_at` (+ `last_status`) or legacy `last_run`.
            let lastRun: String? = if let lr = j["last_run_at"] as? String {
                (j["last_status"] as? String).map { "\(lr) (\($0))" } ?? lr
            } else if let s = j["last_run"] as? String { s }
            else if let d = j["last_run"] as? [String: Any] {
                (d["at"] as? String) ?? (d["status"] as? String)
            } else { nil }
            // status: paused flag wins, else state/status, else active.
            let status: String = if j["enabled"] as? Bool == false { "paused" }
            else { (j["state"] as? String) ?? (j["status"] as? String) ?? "active" }
            let mode = (j["no_agent"] as? Bool == true) ? "script" : "agent"
            return HermesCronJob(
                id: id,
                name: j["name"] as? String,
                schedule: schedule,
                deliver: j["deliver"] as? String,
                lastRun: lastRun,
                status: status,
                mode: mode,
            )
        }
    }
}

/// Structured create spec (filled directly, or by NL → spec via JobIntentClassifier).
struct CronCreateSpec: Codable, ResponseEncodable {
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
    let source: String // "managed" | "byo"
    let jobs: [HermesCronJob]
}
