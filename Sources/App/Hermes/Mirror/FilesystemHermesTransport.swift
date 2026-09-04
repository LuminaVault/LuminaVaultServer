import AsyncHTTPClient
import Crypto
import Foundation
import Logging
import LuminaVaultShared
import NIOCore
import NIOPosix
import Yams

/// Managed transport: the API pod and the managed Hermes share one PVC
/// (`HERMES_GATEWAY_KIND=filesystem`), so skills, cron jobs, config and the
/// KB vault are plain files under the Hermes home. Every file operation runs
/// on `NIOThreadPool.singleton` — never on the cooperative pool.
///
/// Sessions are not files (Hermes keeps them in SQLite), so they come from
/// the tenant's gateway `api_server` (`/api/sessions*`, Bearer API key) via
/// `HermesGatewaySessionsClient`; without a gateway they are `unsupported`.
struct FilesystemHermesTransport: HermesMirrorTransport {
    let kind: HermesMirrorTransportKind = .managed
    /// Hermes home on the PVC (e.g. `/app/data/hermes`). Every path this
    /// transport touches must live inside it.
    let root: URL
    let sessions: HermesGatewaySessionsClient?
    let logger: Logger
    let threadPool: NIOThreadPool
    let clock: @Sendable () -> Date

    init(
        rootPath: String,
        sessions: HermesGatewaySessionsClient? = nil,
        logger: Logger,
        threadPool: NIOThreadPool = .singleton,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        self.sessions = sessions
        self.logger = logger
        self.threadPool = threadPool
        self.clock = clock
    }

    var skillsRoot: URL {
        root.appendingPathComponent("skills", isDirectory: true)
    }

    var configURL: URL {
        root.appendingPathComponent("config.yaml")
    }

    var cronJobsURL: URL {
        root.appendingPathComponent("cron", isDirectory: true).appendingPathComponent("jobs.json")
    }

    // MARK: - Status

    func status() async throws -> HermesDashboardStatus {
        let rootPath = root.path
        let exists = try await threadPool.runIfActive {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return HermesDashboardStatus(reachable: exists, authRequired: false, version: nil, defaultCwd: rootPath)
    }

    // MARK: - Skills

    func listSkills() async throws -> [HermesMirrorSkill] {
        let skillsRoot = skillsRoot
        let configURL = configURL
        return try await threadPool.runIfActive {
            let fm = FileManager.default
            guard fm.fileExists(atPath: skillsRoot.path) else { return [] }
            let disabled = Self.readDisabledSkills(configURL: configURL)
            let names = try fm.contentsOfDirectory(atPath: skillsRoot.path).sorted()
            var skills: [HermesMirrorSkill] = []
            for name in names where !name.hasPrefix(".") {
                let skillFile = skillsRoot.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md")
                guard let data = fm.contents(atPath: skillFile.path), let content = String(data: data, encoding: .utf8) else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                skills.append(HermesMirrorSkill(
                    name: name,
                    description: Self.frontmatterDescription(content),
                    enabled: !disabled.contains(name),
                    source: .custom,
                    contentHash: digest
                ))
            }
            return skills
        }
    }

    func skillContent(name: String) async throws -> String {
        let file = try skillFile(named: name)
        return try await threadPool.runIfActive {
            guard let data = FileManager.default.contents(atPath: file.path), let content = String(data: data, encoding: .utf8) else {
                throw HermesMirrorTransportError.notFound("skill:\(name)")
            }
            return content
        }
    }

    func toggleSkill(name: String, enabled: Bool) async throws {
        _ = try skillFile(named: name)
        let configURL = configURL
        try await threadPool.runIfActive {
            var config = Self.loadConfig(configURL: configURL)
            var skillsSection = (config["skills"] as? [String: Any]) ?? [:]
            var disabled = Set((skillsSection["disabled"] as? [String]) ?? [])
            if enabled {
                disabled.remove(name)
            } else {
                disabled.insert(name)
            }
            skillsSection["disabled"] = disabled.sorted()
            config["skills"] = skillsSection
            let yaml = try Yams.dump(object: config, sortKeys: true)
            try Self.atomicWrite(Data(yaml.utf8), to: configURL)
        }
    }

    func createSkill(name: String, content: String) async throws {
        let file = try skillFile(named: name)
        try await threadPool.runIfActive {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.atomicWrite(Data(content.utf8), to: file)
        }
    }

    private func skillFile(named name: String) throws -> URL {
        guard Self.isSafeSkillName(name) else {
            throw HermesMirrorTransportError.invalidPath("skill:\(name)")
        }
        return skillsRoot.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    static func isSafeSkillName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// `description:` line of the YAML frontmatter, else the first non-heading line.
    static func frontmatterDescription(_ content: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    break
                }
                if line.hasPrefix("description:") {
                    return String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return lines.first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed != "---" && !trimmed.contains(":")
        }?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func loadConfig(configURL: URL) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let text = String(data: data, encoding: .utf8),
              let loaded = try? Yams.load(yaml: text) as? [String: Any]
        else { return [:] }
        return loaded
    }

    static func readDisabledSkills(configURL: URL) -> Set<String> {
        let config = loadConfig(configURL: configURL)
        let section = config["skills"] as? [String: Any]
        return Set((section?["disabled"] as? [String]) ?? [])
    }

    // MARK: - Cron (`cron/jobs.json`)

    func listJobs() async throws -> [HermesMirrorJob] {
        let url = cronJobsURL
        return try await threadPool.runIfActive {
            guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
            return HermesDashboardClient.parseJobs(data)
        }
    }

    /// Appends a job document in the shape `cron/jobs.py` writes so the Hermes
    /// scheduler picks it up on its next reload.
    func createJob(_ spec: HermesMirrorJobSpec) async throws -> HermesMirrorJob {
        let expression = try CronExpression(spec.schedule)
        let now = clock()
        let nextRun = Self.nextRun(after: now, expression: expression)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let document: [String: JSONValue] = [
            "id": .string(String(id)),
            "name": .string(spec.name),
            "prompt": .string(spec.prompt),
            "skills": .array(spec.skills.map(JSONValue.string)),
            "skill": .null,
            "model": spec.model.map(JSONValue.string) ?? .null,
            "provider": spec.provider.map(JSONValue.string) ?? .null,
            "base_url": spec.baseURL.map(JSONValue.string) ?? .null,
            "script": spec.script.map(JSONValue.string) ?? .null,
            "no_agent": .bool(spec.noAgent),
            "context_from": spec.contextFrom.map { .array($0.map(JSONValue.string)) } ?? .null,
            "enabled_toolsets": spec.enabledToolsets.map { .array($0.map(JSONValue.string)) } ?? .null,
            "workdir": spec.workdir.map(JSONValue.string) ?? .null,
            "deliver": .string(spec.deliver),
            "schedule": .object(["kind": .string("cron"), "expr": .string(spec.schedule), "display": .string(spec.schedule)]),
            "schedule_display": .string(spec.schedule),
            "repeat": .object(["times": .null, "completed": .number(0)]),
            "enabled": .bool(true),
            "state": .string("scheduled"),
            "paused_at": .null,
            "paused_reason": .null,
            "created_at": .string(HermesDates.iso(now)),
            "next_run_at": nextRun.map { .string(HermesDates.iso($0)) } ?? .null,
            "last_run_at": .null,
            "last_status": .null,
            "last_error": .null,
        ]
        let encoded = try JSONEncoder().encode(document)
        return try await mutateJobs(now: now) { jobs in
            guard let foundationDocument = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw HermesMirrorTransportError.invalidResponse("jobs.json")
            }
            jobs.append(foundationDocument)
            guard let job = HermesDashboardClient.parseJob(foundationDocument) else {
                throw HermesMirrorTransportError.invalidResponse("jobs.json")
            }
            return job
        }
    }

    /// Mirrors `cron/jobs.py:update_job`: immutable `id`, schedule re-derived
    /// (cron only on the managed path), `enabled: false` pauses.
    func updateJob(id: String, updates: HermesMirrorJobUpdate) async throws -> HermesMirrorJob {
        let jobID = try HermesJobID.validate(id)
        let now = clock()
        // Schedule fields are derived before the closure so only Sendable
        // values (JSON `Data`, the id, the clock) cross to the thread pool.
        let schedulePatch: Data? = try updates.schedule.map { schedule in
            let expression = try CronExpression(schedule)
            let fields: [String: JSONValue] = [
                "schedule": .object(["kind": .string("cron"), "expr": .string(schedule), "display": .string(schedule)]),
                "schedule_display": .string(schedule),
                "next_run_at": Self.nextRun(after: now, expression: expression).map { .string(HermesDates.iso($0)) } ?? .null,
            ]
            return try JSONEncoder().encode(fields)
        }
        let encoded = try JSONEncoder().encode(updates.updates)
        return try await mutateJobs(now: now) { jobs in
            guard let index = jobs.firstIndex(where: { ($0["id"] as? String) == jobID }) else {
                throw HermesMirrorTransportError.notFound("job:\(jobID)")
            }
            var job = jobs[index]
            let fields = try (JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
            for (key, value) in fields where key != "schedule" && key != "id" {
                job[key] = value
            }
            if fields["skills"] != nil {
                job["skill"] = NSNull()
            }
            if let schedulePatch, let scheduleFields = try JSONSerialization.jsonObject(with: schedulePatch) as? [String: Any] {
                for (key, value) in scheduleFields {
                    job[key] = value
                }
            }
            if let enabled = fields["enabled"] as? Bool {
                if enabled {
                    job["state"] = "scheduled"
                    job["paused_at"] = NSNull()
                    job["paused_reason"] = NSNull()
                } else {
                    job["state"] = "paused"
                    job["paused_at"] = HermesDates.iso(now)
                }
            }
            jobs[index] = job
            guard let parsed = HermesDashboardClient.parseJob(job) else {
                throw HermesMirrorTransportError.invalidResponse("jobs.json")
            }
            return parsed
        }
    }

    func pauseJob(id: String) async throws -> HermesMirrorJob {
        let jobID = try HermesJobID.validate(id)
        let now = clock()
        return try await mutateJobs(now: now) { jobs in
            try Self.patchJob(&jobs, id: jobID) { job in
                job["enabled"] = false
                job["state"] = "paused"
                job["paused_at"] = HermesDates.iso(now)
                job["paused_reason"] = NSNull()
            }
        }
    }

    func resumeJob(id: String) async throws -> HermesMirrorJob {
        let jobID = try HermesJobID.validate(id)
        let now = clock()
        return try await mutateJobs(now: now) { jobs in
            try Self.patchJob(&jobs, id: jobID) { job in
                job["enabled"] = true
                job["state"] = "scheduled"
                job["paused_at"] = NSNull()
                job["paused_reason"] = NSNull()
                if let expr = (job["schedule"] as? [String: Any])?["expr"] as? String,
                   let expression = try? CronExpression(expr),
                   let next = Self.nextRun(after: now, expression: expression)
                {
                    job["next_run_at"] = HermesDates.iso(next)
                }
            }
        }
    }

    func triggerJob(id: String) async throws -> HermesMirrorJob {
        let jobID = try HermesJobID.validate(id)
        let now = clock()
        return try await mutateJobs(now: now) { jobs in
            try Self.patchJob(&jobs, id: jobID) { job in
                job["enabled"] = true
                job["state"] = "scheduled"
                job["paused_at"] = NSNull()
                job["paused_reason"] = NSNull()
                job["next_run_at"] = HermesDates.iso(now)
            }
        }
    }

    /// Removes the job and its `cron/output/<id>/` directory (`remove_job`).
    func deleteJob(id: String) async throws {
        let jobID = try HermesJobID.validate(id)
        let outputDirectory = jobOutputDirectory(jobID)
        _ = try await mutateJobs(now: clock()) { jobs in
            guard let index = jobs.firstIndex(where: { ($0["id"] as? String) == jobID }) else {
                throw HermesMirrorTransportError.notFound("job:\(jobID)")
            }
            jobs.remove(at: index)
            try? FileManager.default.removeItem(at: outputDirectory)
            return true
        }
    }

    private static func patchJob(_ jobs: inout [[String: Any]], id: String, _ patch: (inout [String: Any]) -> Void) throws -> HermesMirrorJob {
        guard let index = jobs.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw HermesMirrorTransportError.notFound("job:\(id)")
        }
        var job = jobs[index]
        patch(&job)
        jobs[index] = job
        guard let parsed = HermesDashboardClient.parseJob(job) else {
            throw HermesMirrorTransportError.invalidResponse("jobs.json")
        }
        return parsed
    }

    /// load → mutate → atomic save of `cron/jobs.json` under the same
    /// advisory lock the Hermes scheduler and CLI take (`cron/.jobs.lock`),
    /// so a concurrent Hermes write cannot clobber ours. Runs on the thread
    /// pool; the closure sees the `jobs` array only.
    private func mutateJobs<T: Sendable>(now: Date, _ body: @escaping @Sendable (inout [[String: Any]]) throws -> T) async throws -> T {
        let url = cronJobsURL
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".jobs.lock")
        return try await threadPool.runIfActive {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else {
                throw HermesMirrorTransportError.invalidResponse("jobs.lock")
            }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else {
                throw HermesMirrorTransportError.invalidResponse("jobs.lock")
            }
            defer { flock(fd, LOCK_UN) }
            var envelope: [String: Any] = ["jobs": [[String: Any]]()]
            if let data = fm.contents(atPath: url.path),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                envelope = existing
            }
            var jobs = (envelope["jobs"] as? [[String: Any]]) ?? []
            let result = try body(&jobs)
            envelope["jobs"] = jobs
            envelope["updated_at"] = HermesDates.iso(now)
            let payload = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
            try Self.atomicWrite(payload, to: url)
            return result
        }
    }

    // MARK: - Cron runs (`cron/output/<job>/<stamp>.md`)

    func jobOutputDirectory(_ jobID: String) -> URL {
        root.appendingPathComponent("cron", isDirectory: true)
            .appendingPathComponent("output", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
    }

    /// Every `save_job_output` file is one completed run (`cron/jobs.py`);
    /// the file stem `yyyy-MM-dd_HH-mm-ss` is the run key and start time. A
    /// job whose `last_status` is `error` after its newest output file gets
    /// one synthetic `error-<iso>` run carrying `last_error`, since failed
    /// runs write no file.
    func jobRuns(jobID: String, limit: Int) async throws -> [HermesMirrorJobRun] {
        let id = try HermesJobID.validate(jobID)
        let directory = jobOutputDirectory(id)
        let jobsURL = cronJobsURL
        let bounded = max(1, min(limit, 100))
        return try await threadPool.runIfActive {
            let fm = FileManager.default
            var runs: [HermesMirrorJobRun] = []
            if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
                for name in names where name.hasSuffix(".md") && !name.hasPrefix(".") {
                    let stem = String(name.dropLast(3))
                    guard let started = Self.parseOutputStamp(stem) else { continue }
                    runs.append(HermesMirrorJobRun(key: stem, status: .ok, startedAt: started, finishedAt: started))
                }
            }
            if let data = fm.contents(atPath: jobsURL.path),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let job = (object["jobs"] as? [[String: Any]])?.first(where: { ($0["id"] as? String) == id }),
               (job["last_status"] as? String) == "error",
               let lastRun = HermesDates.parse(job["last_run_at"]),
               runs.allSatisfy({ $0.startedAt < lastRun })
            {
                let stamp = HermesDates.iso(lastRun)
                runs.append(HermesMirrorJobRun(key: "error-\(stamp)", status: .error, startedAt: lastRun, finishedAt: lastRun, error: (job["last_error"] as? String) ?? "run failed"))
            }
            return Array(runs.sorted { $0.startedAt > $1.startedAt }.prefix(bounded))
        }
    }

    func jobRunOutput(jobID: String, runKey: String) async throws -> String? {
        let id = try HermesJobID.validate(jobID)
        guard Self.parseOutputStamp(runKey) != nil else { return nil }
        let file = jobOutputDirectory(id).appendingPathComponent("\(runKey).md")
        return try await threadPool.runIfActive {
            guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// `yyyy-MM-dd_HH-mm-ss` (`save_job_output`), read as UTC.
    static func parseOutputStamp(_ stem: String) -> Date? {
        let parts = stem.split(separator: "_")
        guard parts.count == 2 else { return nil }
        let date = parts[0].split(separator: "-").compactMap { Int($0) }
        let time = parts[1].split(separator: "-").compactMap { Int($0) }
        guard date.count == 3, time.count == 3 else { return nil }
        var components = DateComponents()
        components.year = date[0]
        components.month = date[1]
        components.day = date[2]
        components.hour = time[0]
        components.minute = time[1]
        components.second = time[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)
    }

    /// Next minute (UTC) matching the expression within 366 days, else nil.
    static func nextRun(after date: Date, expression: CronExpression) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var candidate = calendar.date(bySetting: .second, value: 0, of: date) ?? date
        candidate = candidate.addingTimeInterval(60)
        for _ in 0 ..< (366 * 24 * 60) {
            if expression.matches(candidate, in: calendar.timeZone) {
                return candidate
            }
            candidate = candidate.addingTimeInterval(60)
        }
        return nil
    }

    // MARK: - Filesystem (KB vault on the PVC)

    func listFiles(path: String) async throws -> [HermesMirrorFileEntry] {
        let directory = try resolveInsideRoot(path)
        return try await threadPool.runIfActive {
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HermesMirrorTransportError.notFound(directory)
            }
            return try fm.contentsOfDirectory(atPath: directory)
                .sorted()
                .map { name in
                    let full = HermesMirrorPath.join(directory, name)
                    var childIsDirectory: ObjCBool = false
                    _ = fm.fileExists(atPath: full, isDirectory: &childIsDirectory)
                    return HermesMirrorFileEntry(name: name, path: full, isDirectory: childIsDirectory.boolValue)
                }
        }
    }

    func readText(path: String) async throws -> String {
        let file = try resolveInsideRoot(path)
        return try await threadPool.runIfActive {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            if let size = attributes?[.size] as? NSNumber, size.intValue > HermesDashboardClient.fileBodyCap {
                throw HermesMirrorTransportError.bodyTooLarge(path: file, limit: HermesDashboardClient.fileBodyCap)
            }
            guard let data = FileManager.default.contents(atPath: file) else {
                throw HermesMirrorTransportError.notFound(file)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw HermesMirrorTransportError.invalidResponse("binary:\(file)")
            }
            return text
        }
    }

    func writeText(path: String, content: String) async throws {
        let file = try resolveInsideRoot(path)
        guard content.utf8.count <= HermesDashboardClient.fileBodyCap else {
            throw HermesMirrorTransportError.bodyTooLarge(path: file, limit: HermesDashboardClient.fileBodyCap)
        }
        try await threadPool.runIfActive {
            let parent = (file as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HermesMirrorTransportError.notFound(parent)
            }
            try Self.atomicWrite(Data(content.utf8), to: URL(fileURLWithPath: file))
        }
    }

    func mkdir(path: String) async throws {
        let directory = try resolveInsideRoot(path)
        try await threadPool.runIfActive {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    /// Validates the path and pins it under `root`. Symlinks are not followed
    /// for the check (the PVC is ours), but `..` and root escapes are rejected.
    func resolveInsideRoot(_ path: String) throws -> String {
        let validated = try HermesMirrorPath.validate(path)
        var rootPath = root.path
        while rootPath.count > 1, rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        guard HermesMirrorPath.isInside(validated, root: rootPath) else {
            throw HermesMirrorTransportError.invalidPath(path)
        }
        return validated
    }

    // MARK: - Sessions (gateway HTTP)

    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage {
        guard let sessions else { throw HermesMirrorTransportError.unsupported("sessions") }
        return try await sessions.listSessions(offset: offset, limit: limit)
    }

    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage] {
        guard let sessions else { throw HermesMirrorTransportError.unsupported("sessions") }
        return try await sessions.sessionMessages(id: id)
    }

    // MARK: - IO helpers

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lv-tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

/// Sessions over the gateway `api_server` (`/api/sessions`,
/// `/api/sessions/{id}/messages`, Bearer API key). Same wire shapes as the
/// dashboard, so the parsers are shared.
struct HermesGatewaySessionsClient: Sendable {
    let baseURL: URL
    let authHeader: String?
    let http: any HermesHTTPExecuting
    let logger: Logger

    init(baseURL: URL, authHeader: String?, http: any HermesHTTPExecuting = AsyncHTTPClientHermesHTTP(), logger: Logger) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.http = http
        self.logger = logger
    }

    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage {
        let response = try await get("api/sessions", query: [("limit", String(limit)), ("offset", String(offset)), ("order", "recent"), ("min_messages", "1")], cap: HermesDashboardClient.listBodyCap)
        guard response.isSuccess else {
            throw HermesMirrorTransportError.http(status: response.status, path: "/api/sessions")
        }
        return HermesDashboardClient.parseSessions(response.json())
    }

    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage] {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response = try await get("api/sessions/\(encodedID)/messages", query: [("limit", "500")], cap: HermesDashboardClient.listBodyCap)
        if response.status == 404 {
            throw HermesMirrorTransportError.notFound("session:\(id)")
        }
        guard response.isSuccess else {
            throw HermesMirrorTransportError.http(status: response.status, path: "/api/sessions/{id}/messages")
        }
        return HermesDashboardClient.parseMessages(response.json())
    }

    private func get(_ path: String, query: [(String, String)], cap: Int) async throws -> HermesHTTPResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw HermesMirrorTransportError.invalidResponse("url")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url?.absoluteString else {
            throw HermesMirrorTransportError.invalidResponse("url")
        }
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")
        if let authHeader, !authHeader.isEmpty {
            request.headers.add(name: "Authorization", value: authHeader)
        }
        do {
            return try await http.execute(request, timeout: HermesDashboardClient.timeout, maxBodyBytes: cap)
        } catch let error as HermesMirrorTransportError {
            throw error
        } catch {
            logger.debug("hermes gateway sessions request failed", metadata: ["path": "\(path)", "error": "\(Logger.redact(String(describing: error)))"])
            throw HermesMirrorTransportError.dashboardUnreachable(path)
        }
    }
}
