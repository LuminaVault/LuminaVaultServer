import Foundation
import LuminaVaultShared

/// Hermes Mirror — one seam over the two Hermes surfaces (gateway `api_server`
/// for reads, dashboard `web_server` for writes/cron/fs/sessions) so
/// `HermesMirrorService` is transport-agnostic. `RemoteHermesTransport`
/// serves BYO tenants over HTTP; `FilesystemHermesTransport` serves managed
/// tenants from the shared PVC. Tests use `FakeHermesMirrorTransport`.
protocol HermesMirrorTransport: Sendable {
    var kind: HermesMirrorTransportKind { get }

    /// Liveness + version + default working directory of the Hermes.
    func status() async throws -> HermesDashboardStatus
    func listSkills() async throws -> [HermesMirrorSkill]
    func skillContent(name: String) async throws -> String
    func toggleSkill(name: String, enabled: Bool) async throws
    func createSkill(name: String, content: String) async throws
    func listJobs() async throws -> [HermesMirrorJob]
    func createJob(_ spec: HermesMirrorJobSpec) async throws -> HermesMirrorJob
    /// Partial update; returns the job as Hermes stores it afterwards.
    func updateJob(id: String, updates: HermesMirrorJobUpdate) async throws -> HermesMirrorJob
    func pauseJob(id: String) async throws -> HermesMirrorJob
    func resumeJob(id: String) async throws -> HermesMirrorJob
    /// Schedules the job to fire on the next scheduler tick.
    func triggerJob(id: String) async throws -> HermesMirrorJob
    func deleteJob(id: String) async throws
    /// Run history for one job, newest first, at most `limit` entries.
    /// Outputs are not included — `jobRunOutput` fetches them one at a time so
    /// only new runs cost a read.
    func jobRuns(jobID: String, limit: Int) async throws -> [HermesMirrorJobRun]
    /// Markdown a run produced, nil when Hermes kept nothing for it.
    func jobRunOutput(jobID: String, runKey: String) async throws -> String?
    func listFiles(path: String) async throws -> [HermesMirrorFileEntry]
    func readText(path: String) async throws -> String
    func writeText(path: String, content: String) async throws
    func mkdir(path: String) async throws
    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage
    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage]
}

struct HermesDashboardStatus: Sendable, Equatable {
    let reachable: Bool
    /// `auth_required` from `/api/status` — true means the OAuth/password gate
    /// is on and a static bearer cannot reach protected `/api/*` routes.
    let authRequired: Bool?
    let version: String?
    /// Working directory the dashboard resolves relative paths against.
    let defaultCwd: String?
    /// `admin_config_rw` as the Hermes reports it: this Hermes lets an admin
    /// read and write its own configuration, which is what a user needs in
    /// order to store an outbound webhook URL and secret. Nil means the
    /// Hermes said nothing, which is treated as "no" — the inbound webhook is
    /// an optimisation, so refusing to offer one costs only latency.
    let adminConfigRW: Bool?

    init(reachable: Bool, authRequired: Bool?, version: String?, defaultCwd: String?, adminConfigRW: Bool? = nil) {
        self.reachable = reachable
        self.authRequired = authRequired
        self.version = version
        self.defaultCwd = defaultCwd
        self.adminConfigRW = adminConfigRW
    }
}

struct HermesMirrorSkill: Sendable, Equatable {
    let name: String
    let description: String
    let enabled: Bool
    let source: HermesMirroredSkillSource
    /// SHA-256 of `SKILL.md` when the transport can compute it cheaply.
    let contentHash: String?
}

struct HermesMirrorJob: Sendable, Equatable {
    let id: String
    let name: String?
    let schedule: String?
    let prompt: String?
    let paused: Bool
    let lastRunAt: Date?
    let nextRunAt: Date?
    /// Source document as Hermes sent it (stored in `hermes_mirrored_jobs.raw`).
    let raw: JSONValue
}

/// Full Hermes `CronJobCreate` body (`web_server.py:10032`). Everything past
/// `skills` is optional and omitted from the wire body when nil.
struct HermesMirrorJobSpec: Sendable, Equatable {
    let name: String
    let schedule: String
    let prompt: String
    let deliver: String
    let skills: [String]
    var model: String?
    var provider: String?
    var baseURL: String?
    var script: String?
    var contextFrom: [String]?
    var enabledToolsets: [String]?
    var workdir: String?
    var noAgent = false

    init(
        name: String,
        schedule: String,
        prompt: String,
        deliver: String,
        skills: [String],
        model: String? = nil,
        provider: String? = nil,
        baseURL: String? = nil,
        script: String? = nil,
        contextFrom: [String]? = nil,
        enabledToolsets: [String]? = nil,
        workdir: String? = nil,
        noAgent: Bool = false
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.deliver = deliver
        self.skills = skills
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.script = script
        self.contextFrom = contextFrom
        self.enabledToolsets = enabledToolsets
        self.workdir = workdir
        self.noAgent = noAgent
    }

    init(_ request: HermesJobCreateRequest) {
        self.init(
            name: request.name,
            schedule: request.schedule,
            prompt: request.prompt ?? "",
            deliver: request.deliver ?? "origin",
            skills: request.skills ?? [],
            model: request.model,
            provider: request.provider,
            baseURL: request.baseURL,
            script: request.script,
            contextFrom: request.contextFrom,
            enabledToolsets: request.enabledToolsets,
            workdir: request.workdir,
            noAgent: request.noAgent ?? false
        )
    }

    /// Wire body for `POST /api/cron/jobs`; nil optionals are left out so
    /// Hermes applies its own defaults.
    var body: [String: JSONValue] {
        var body: [String: JSONValue] = [
            "name": .string(name),
            "schedule": .string(schedule),
            "prompt": .string(prompt),
            "deliver": .string(deliver),
            "skills": .array(skills.map(JSONValue.string)),
            "no_agent": .bool(noAgent),
        ]
        if let model {
            body["model"] = .string(model)
        }
        if let provider {
            body["provider"] = .string(provider)
        }
        if let baseURL {
            body["base_url"] = .string(baseURL)
        }
        if let script {
            body["script"] = .string(script)
        }
        if let contextFrom {
            body["context_from"] = .array(contextFrom.map(JSONValue.string))
        }
        if let enabledToolsets {
            body["enabled_toolsets"] = .array(enabledToolsets.map(JSONValue.string))
        }
        if let workdir {
            body["workdir"] = .string(workdir)
        }
        return body
    }
}

/// Partial job update — the `updates` dict of `PUT /api/cron/jobs/{id}`
/// (`CronJobUpdate`). Only set fields are sent; `id` is immutable on Hermes.
struct HermesMirrorJobUpdate: Sendable, Equatable {
    var name: String?
    var schedule: String?
    var prompt: String?
    var deliver: String?
    var skills: [String]?
    var model: String?
    var provider: String?
    var baseURL: String?
    var script: String?
    var contextFrom: [String]?
    var enabledToolsets: [String]?
    var workdir: String?
    var noAgent: Bool?
    var enabled: Bool?

    init(
        name: String? = nil,
        schedule: String? = nil,
        prompt: String? = nil,
        deliver: String? = nil,
        skills: [String]? = nil,
        model: String? = nil,
        provider: String? = nil,
        baseURL: String? = nil,
        script: String? = nil,
        contextFrom: [String]? = nil,
        enabledToolsets: [String]? = nil,
        workdir: String? = nil,
        noAgent: Bool? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.deliver = deliver
        self.skills = skills
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.script = script
        self.contextFrom = contextFrom
        self.enabledToolsets = enabledToolsets
        self.workdir = workdir
        self.noAgent = noAgent
        self.enabled = enabled
    }

    init(_ request: HermesJobUpdateRequest) {
        self.init(
            name: request.name,
            schedule: request.schedule,
            prompt: request.prompt,
            deliver: request.deliver,
            skills: request.skills,
            model: request.model,
            provider: request.provider,
            baseURL: request.baseURL,
            script: request.script,
            contextFrom: request.contextFrom,
            enabledToolsets: request.enabledToolsets,
            workdir: request.workdir,
            noAgent: request.noAgent,
            enabled: request.enabled
        )
    }

    /// Hermes-side field names → values.
    var updates: [String: JSONValue] {
        var updates: [String: JSONValue] = [:]
        if let name {
            updates["name"] = .string(name)
        }
        if let schedule {
            updates["schedule"] = .string(schedule)
        }
        if let prompt {
            updates["prompt"] = .string(prompt)
        }
        if let deliver {
            updates["deliver"] = .string(deliver)
        }
        if let skills {
            updates["skills"] = .array(skills.map(JSONValue.string))
        }
        if let model {
            updates["model"] = .string(model)
        }
        if let provider {
            updates["provider"] = .string(provider)
        }
        if let baseURL {
            updates["base_url"] = .string(baseURL)
        }
        if let script {
            updates["script"] = .string(script)
        }
        if let contextFrom {
            updates["context_from"] = .array(contextFrom.map(JSONValue.string))
        }
        if let enabledToolsets {
            updates["enabled_toolsets"] = .array(enabledToolsets.map(JSONValue.string))
        }
        if let workdir {
            updates["workdir"] = .string(workdir)
        }
        if let noAgent {
            updates["no_agent"] = .bool(noAgent)
        }
        if let enabled {
            updates["enabled"] = .bool(enabled)
        }
        return updates
    }

    var isEmpty: Bool {
        updates.isEmpty
    }
}

/// One run of a Hermes cron job as the transport lists it.
struct HermesMirrorJobRun: Sendable, Equatable {
    /// Unique per job on the Hermes side (session id / output file stem).
    let key: String
    let status: HermesJobRunStatus
    let startedAt: Date
    let finishedAt: Date?
    let error: String?
    let tokensIn: Int?
    let tokensOut: Int?

    init(key: String, status: HermesJobRunStatus, startedAt: Date, finishedAt: Date? = nil, error: String? = nil, tokensIn: Int? = nil, tokensOut: Int? = nil) {
        self.key = key
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
    }
}

/// Hermes job ids are single path components (`cron/output/<id>/`), so the
/// same rule guards URL paths on the dashboard and directories on the PVC.
enum HermesJobID {
    static func validate(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128, id != ".", id != "..",
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else {
            throw HermesMirrorTransportError.invalidPath("job:\(raw)")
        }
        return id
    }
}

struct HermesMirrorFileEntry: Sendable, Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
}

struct HermesMirrorSession: Sendable, Equatable {
    let id: String
    let title: String?
    let source: String?
    let startedAt: Date?
    let lastActiveAt: Date?
    let messageCount: Int
}

struct HermesMirrorSessionPage: Sendable, Equatable {
    let sessions: [HermesMirrorSession]
    let total: Int?
}

struct HermesMirrorSessionMessage: Sendable, Equatable {
    let role: String
    let content: String
    let timestamp: Date?
}

enum HermesMirrorTransportError: Error, Equatable, CustomStringConvertible {
    /// The transport has no implementation of this operation for the tenant.
    case unsupported(String)
    case http(status: UInt, path: String)
    case bodyTooLarge(path: String, limit: Int)
    case invalidPath(String)
    case notFound(String)
    case invalidResponse(String)
    /// Dashboard is gated (OAuth/password); the bearer path does not exist.
    case dashboardAuthModeUnsupported
    case dashboardUnauthorized
    case dashboardUnreachable(String)
    case notConfigured

    var description: String {
        switch self {
        case let .unsupported(op): "hermes_mirror_unsupported:\(op)"
        case let .http(status, path): "hermes_mirror_http_\(status):\(path)"
        case let .bodyTooLarge(path, limit): "hermes_mirror_body_too_large:\(path):\(limit)"
        case let .invalidPath(path): "hermes_mirror_invalid_path:\(path)"
        case let .notFound(what): "hermes_mirror_not_found:\(what)"
        case let .invalidResponse(what): "hermes_mirror_invalid_response:\(what)"
        case .dashboardAuthModeUnsupported: "hermes_dashboard_auth_mode_unsupported"
        case .dashboardUnauthorized: "hermes_dashboard_unauthorized"
        case let .dashboardUnreachable(reason): "hermes_dashboard_unreachable:\(reason)"
        case .notConfigured: "hermes_mirror_not_configured"
        }
    }

    /// Stable client-facing code (no host names, no reasons).
    var code: String {
        switch self {
        case .unsupported: "hermes_mirror_unsupported"
        case .http: "hermes_mirror_upstream_error"
        case .bodyTooLarge: "hermes_mirror_body_too_large"
        case .invalidPath: "hermes_mirror_invalid_path"
        case .notFound: "hermes_mirror_not_found"
        case .invalidResponse: "hermes_mirror_invalid_response"
        case .dashboardAuthModeUnsupported: "hermes_dashboard_auth_mode_unsupported"
        case .dashboardUnauthorized: "hermes_dashboard_unauthorized"
        case .dashboardUnreachable: "hermes_dashboard_unreachable"
        case .notConfigured: "hermes_mirror_not_configured"
        }
    }
}

/// Path rules shared by every transport: absolute, no NUL, no `.`/`..`
/// segments, no empty segments. Applied before a path reaches Hermes or the
/// PVC so a mirrored vault can never escape its root.
enum HermesMirrorPath {
    static func validate(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
            throw HermesMirrorTransportError.invalidPath(raw)
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        for segment in segments where segment == "." || segment == ".." {
            throw HermesMirrorTransportError.invalidPath(raw)
        }
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    /// True when `path` is `root` or lives below it.
    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Date parsing for the mixed formats Hermes emits: ISO-8601 with or without
/// fractional seconds/offset, or epoch seconds.
enum HermesDates {
    static func parse(_ value: Any?) -> Date? {
        switch value {
        case let seconds as Double:
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        case let seconds as Int:
            return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        case let number as NSNumber:
            let seconds = number.doubleValue
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        case let string as String:
            return parseISO(string)
        default:
            return nil
        }
    }

    static func parseISO(_ raw: String) -> Date? {
        let string = raw.trimmingCharacters(in: .whitespaces)
        guard !string.isEmpty else { return nil }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        // Python `isoformat()` without offset ("2026-06-08T19:32:59.622927").
        let withZone = string + "Z"
        if let date = try? Date(withZone, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(withZone, strategy: Date.ISO8601FormatStyle())
    }

    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

extension JSONValue {
    /// Bridge from `JSONSerialization` output.
    init(foundation value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // `JSONSerialization` boxes booleans and numbers alike in
            // `NSNumber`, and `as? Bool` succeeds for 0 and 1 either way, so
            // the box has to be interrogated. `CFBooleanGetTypeID` did that
            // and is Darwin-only — it compiled on macOS and broke the Linux
            // build, which is what CI runs. The ObjC type encoding is the
            // portable form of the same question: a boxed boolean reports "c".
            if String(cString: number.objCType) == "c" {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let bool as Bool: self = .bool(bool)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .string(String(describing: value))
        }
    }
}
