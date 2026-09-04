@testable import App
import AsyncHTTPClient
import Foundation
import LuminaVaultShared
import NIOCore
import NIOHTTP1

/// In-memory `HermesMirrorTransport` for service/controller tests. Every
/// operation is scriptable per method and records calls so tests can assert
/// what reached "Hermes".
actor FakeHermesMirrorTransport: HermesMirrorTransport {
    nonisolated let kind: HermesMirrorTransportKind
    var skills: [HermesMirrorSkill] = []
    var skillContents: [String: String] = [:]
    var jobs: [HermesMirrorJob] = []
    var files: [String: String] = [:]
    var directories: Set<String> = []
    var sessions: [HermesMirrorSession] = []
    var messages: [String: [HermesMirrorSessionMessage]] = [:]
    /// Hermes job id → runs the fake reports, newest first is not assumed;
    /// `jobRuns` sorts and caps like the real transports do.
    var runs: [String: [HermesMirrorJobRun]] = [:]
    /// "<jobID>/<runKey>" → markdown; absent means Hermes kept no output.
    var runOutputs: [String: String] = [:]
    var statusResult = HermesDashboardStatus(reachable: true, authRequired: false, version: "0.20.0", defaultCwd: "/home/hermes")
    /// Operation name → error to throw.
    var failures: [String: HermesMirrorTransportError] = [:]
    private(set) var calls: [String] = []

    init(kind: HermesMirrorTransportKind = .remote) {
        self.kind = kind
    }

    func fail(_ operation: String, with error: HermesMirrorTransportError) {
        failures[operation] = error
    }

    func setSkills(_ value: [HermesMirrorSkill]) {
        skills = value
    }

    func setJobs(_ value: [HermesMirrorJob]) {
        jobs = value
    }

    func setSessions(_ value: [HermesMirrorSession]) {
        sessions = value
    }

    func setRuns(_ jobID: String, _ value: [HermesMirrorJobRun]) {
        runs[jobID] = value
    }

    func setRunOutput(_ jobID: String, _ runKey: String, _ output: String?) {
        runOutputs["\(jobID)/\(runKey)"] = output
    }

    func setMessages(_ id: String, _ value: [HermesMirrorSessionMessage]) {
        messages[id] = value
    }

    func setStatus(_ value: HermesDashboardStatus) {
        statusResult = value
    }

    func addDirectory(_ path: String) {
        directories.insert(path)
    }

    func addFile(_ path: String, _ content: String) {
        files[path] = content
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            directories.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        directories.insert("/")
    }

    func recordedCalls() -> [String] {
        calls
    }

    func fileContents() -> [String: String] {
        files
    }

    func directoryList() -> Set<String> {
        directories
    }

    func jobList() -> [HermesMirrorJob] {
        jobs
    }

    func skillList() -> [HermesMirrorSkill] {
        skills
    }

    private func check(_ operation: String) throws {
        calls.append(operation)
        if let error = failures[operation] {
            throw error
        }
    }

    func status() async throws -> HermesDashboardStatus {
        try check("status")
        return statusResult
    }

    func listSkills() async throws -> [HermesMirrorSkill] {
        try check("listSkills")
        return skills
    }

    func skillContent(name: String) async throws -> String {
        try check("skillContent")
        guard let content = skillContents[name] else { throw HermesMirrorTransportError.notFound("skill:\(name)") }
        return content
    }

    func toggleSkill(name: String, enabled: Bool) async throws {
        try check("toggleSkill:\(name):\(enabled)")
        guard let index = skills.firstIndex(where: { $0.name == name }) else {
            throw HermesMirrorTransportError.notFound("skill:\(name)")
        }
        let old = skills[index]
        skills[index] = HermesMirrorSkill(name: old.name, description: old.description, enabled: enabled, source: old.source, contentHash: old.contentHash)
    }

    func createSkill(name: String, content: String) async throws {
        try check("createSkill:\(name)")
        skillContents[name] = content
        skills.append(HermesMirrorSkill(name: name, description: FilesystemHermesTransport.frontmatterDescription(content), enabled: true, source: .custom, contentHash: nil))
    }

    func listJobs() async throws -> [HermesMirrorJob] {
        try check("listJobs")
        return jobs
    }

    func createJob(_ spec: HermesMirrorJobSpec) async throws -> HermesMirrorJob {
        try check("createJob:\(spec.name)")
        let job = HermesMirrorJob(
            id: "job-\(jobs.count + 1)",
            name: spec.name,
            schedule: spec.schedule,
            prompt: spec.prompt,
            paused: false,
            lastRunAt: nil,
            nextRunAt: nil,
            raw: .object(["name": .string(spec.name), "schedule": .string(spec.schedule)])
        )
        jobs.append(job)
        return job
    }

    func updateJob(id: String, updates: HermesMirrorJobUpdate) async throws -> HermesMirrorJob {
        try check("updateJob:\(id)")
        return try mutate(id) { job in
            HermesMirrorJob(
                id: job.id,
                name: updates.name ?? job.name,
                schedule: updates.schedule ?? job.schedule,
                prompt: updates.prompt ?? job.prompt,
                paused: updates.enabled.map { !$0 } ?? job.paused,
                lastRunAt: job.lastRunAt,
                nextRunAt: job.nextRunAt,
                raw: job.raw
            )
        }
    }

    func pauseJob(id: String) async throws -> HermesMirrorJob {
        try check("pauseJob:\(id)")
        return try mutate(id) { Self.repaused($0, paused: true) }
    }

    func resumeJob(id: String) async throws -> HermesMirrorJob {
        try check("resumeJob:\(id)")
        return try mutate(id) { Self.repaused($0, paused: false) }
    }

    func triggerJob(id: String) async throws -> HermesMirrorJob {
        try check("triggerJob:\(id)")
        return try mutate(id) { Self.repaused($0, paused: false) }
    }

    func deleteJob(id: String) async throws {
        try check("deleteJob:\(id)")
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            throw HermesMirrorTransportError.notFound("job:\(id)")
        }
        jobs.remove(at: index)
        runs[id] = nil
    }

    func jobRuns(jobID: String, limit: Int) async throws -> [HermesMirrorJobRun] {
        try check("jobRuns:\(jobID)")
        let rows = runs[jobID] ?? []
        return Array(rows.sorted { $0.startedAt > $1.startedAt }.prefix(max(1, limit)))
    }

    func jobRunOutput(jobID: String, runKey: String) async throws -> String? {
        try check("jobRunOutput:\(jobID):\(runKey)")
        return runOutputs["\(jobID)/\(runKey)"]
    }

    private func mutate(_ id: String, _ patch: (HermesMirrorJob) -> HermesMirrorJob) throws -> HermesMirrorJob {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            throw HermesMirrorTransportError.notFound("job:\(id)")
        }
        let updated = patch(jobs[index])
        jobs[index] = updated
        return updated
    }

    private static func repaused(_ job: HermesMirrorJob, paused: Bool) -> HermesMirrorJob {
        HermesMirrorJob(
            id: job.id, name: job.name, schedule: job.schedule, prompt: job.prompt,
            paused: paused, lastRunAt: job.lastRunAt, nextRunAt: job.nextRunAt, raw: job.raw
        )
    }

    func listFiles(path: String) async throws -> [HermesMirrorFileEntry] {
        try check("listFiles:\(path)")
        let validated = try HermesMirrorPath.validate(path)
        guard directories.contains(validated) else { throw HermesMirrorTransportError.notFound(validated) }
        var entries: [HermesMirrorFileEntry] = []
        for directory in directories where (directory as NSString).deletingLastPathComponent == validated && directory != validated {
            entries.append(HermesMirrorFileEntry(name: (directory as NSString).lastPathComponent, path: directory, isDirectory: true))
        }
        for file in files.keys where (file as NSString).deletingLastPathComponent == validated {
            entries.append(HermesMirrorFileEntry(name: (file as NSString).lastPathComponent, path: file, isDirectory: false))
        }
        return entries.sorted { $0.name < $1.name }
    }

    func readText(path: String) async throws -> String {
        try check("readText:\(path)")
        guard let content = files[path] else { throw HermesMirrorTransportError.notFound(path) }
        return content
    }

    func writeText(path: String, content: String) async throws {
        try check("writeText:\(path)")
        files[path] = content
    }

    func mkdir(path: String) async throws {
        try check("mkdir:\(path)")
        try directories.insert(HermesMirrorPath.validate(path))
    }

    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage {
        try check("listSessions:\(offset):\(limit)")
        let slice = Array(sessions.dropFirst(offset).prefix(limit))
        return HermesMirrorSessionPage(sessions: slice, total: sessions.count)
    }

    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage] {
        try check("sessionMessages:\(id)")
        guard let rows = messages[id] else { throw HermesMirrorTransportError.notFound("session:\(id)") }
        return rows
    }
}

/// Scriptable `HermesHTTPExecuting`: responses keyed by `METHOD path`
/// (query stripped). Records every request for assertions.
final class StubHermesHTTP: HermesHTTPExecuting, @unchecked Sendable {
    // `@unchecked`: all state lives behind `lock`; the class is a test double.
    struct Recorded: Sendable {
        let method: String
        let url: String
        let headers: [(String, String)]
        let body: String?
    }

    private let lock = NSLock()
    private var responses: [String: [HermesHTTPResponse]] = [:]
    private var recorded: [Recorded] = []
    private var failureBox: (any Error)?

    init() {}

    var failure: (any Error)? {
        get { lock.withLock { failureBox } }
        set { lock.withLock { failureBox = newValue } }
    }

    func respond(_ method: String, _ path: String, status: UInt = 200, json: String = "{}", headers: [(String, String)] = []) {
        var httpHeaders = HTTPHeaders()
        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }
        let response = HermesHTTPResponse(status: status, headers: httpHeaders, body: ByteBuffer(string: json))
        lock.withLock { responses["\(method) \(path)", default: []].append(response) }
    }

    var requests: [Recorded] {
        lock.withLock { recorded }
    }

    func execute(_ request: HTTPClientRequest, timeout _: TimeAmount, maxBodyBytes _: Int) async throws -> HermesHTTPResponse {
        if let failure {
            throw failure
        }
        let path = URLComponents(string: request.url)?.path ?? request.url
        var bodyString: String?
        if let body = request.body {
            var collected = ByteBuffer()
            for try await chunk in body {
                var chunk = chunk
                collected.writeBuffer(&chunk)
            }
            bodyString = String(buffer: collected)
        }
        let key = "\(request.method.rawValue) \(path)"
        let response: HermesHTTPResponse? = lock.withLock {
            recorded.append(Recorded(method: request.method.rawValue, url: request.url, headers: request.headers.map { ($0.name, $0.value) }, body: bodyString))
            guard var queue = responses[key], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            responses[key] = queue
            return next
        }
        guard let response else {
            return HermesHTTPResponse(status: 404, headers: HTTPHeaders(), body: ByteBuffer(string: #"{"detail":"Not Found"}"#))
        }
        return response
    }
}
