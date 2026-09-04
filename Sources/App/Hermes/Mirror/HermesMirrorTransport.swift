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

struct HermesMirrorJobSpec: Sendable, Equatable {
    let name: String
    let schedule: String
    let prompt: String
    let deliver: String
    let skills: [String]
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
        case let bool as Bool where CFGetTypeID(bool as CFTypeRef) == CFBooleanGetTypeID(): self = .bool(bool)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .string(String(describing: value))
        }
    }
}
