import Foundation
import Logging
import LuminaVaultShared

/// BYO transport: gateway `api_server` for the read-only skill list (via the
/// existing `HermesSkillsClient`) and the dashboard for everything else.
/// Reads that the dashboard can serve better (skill descriptions + enabled
/// flags) come from the dashboard; the gateway list is the fallback when the
/// dashboard is unreachable so `GET /v1/skills` keeps working.
struct RemoteHermesTransport: HermesMirrorTransport {
    let kind: HermesMirrorTransportKind = .remote
    let gatewayBaseURL: URL?
    let gatewayAuthHeader: String?
    let skillsClient: any HermesSkillsClienting
    let dashboard: HermesDashboardClient
    let logger: Logger

    func status() async throws -> HermesDashboardStatus {
        try await dashboard.status()
    }

    func listSkills() async throws -> [HermesMirrorSkill] {
        do {
            return try await dashboard.listSkills()
        } catch let error as HermesMirrorTransportError {
            guard let gatewayBaseURL else { throw error }
            logger.debug("dashboard skills unavailable; falling back to gateway", metadata: ["error": "\(error)"])
            let entries = await skillsClient.installedSkills(baseURL: gatewayBaseURL, authHeader: gatewayAuthHeader)
            guard !entries.isEmpty else { throw error }
            return entries.map { entry in
                HermesMirrorSkill(name: entry.name, description: entry.summary, enabled: true, source: .custom, contentHash: nil)
            }
        }
    }

    func skillContent(name: String) async throws -> String {
        try await dashboard.skillContent(name: name)
    }

    func toggleSkill(name: String, enabled: Bool) async throws {
        try await dashboard.toggleSkill(name: name, enabled: enabled)
    }

    func createSkill(name: String, content: String) async throws {
        try await dashboard.createSkill(name: name, content: content)
    }

    func listJobs() async throws -> [HermesMirrorJob] {
        try await dashboard.listJobs()
    }

    func createJob(_ spec: HermesMirrorJobSpec) async throws -> HermesMirrorJob {
        try await dashboard.createJob(spec)
    }

    func updateJob(id: String, updates: HermesMirrorJobUpdate) async throws -> HermesMirrorJob {
        try await dashboard.updateJob(id: id, updates: updates)
    }

    func pauseJob(id: String) async throws -> HermesMirrorJob {
        try await dashboard.pauseJob(id: id)
    }

    func resumeJob(id: String) async throws -> HermesMirrorJob {
        try await dashboard.resumeJob(id: id)
    }

    func triggerJob(id: String) async throws -> HermesMirrorJob {
        try await dashboard.triggerJob(id: id)
    }

    func deleteJob(id: String) async throws {
        try await dashboard.deleteJob(id: id)
    }

    func jobRuns(jobID: String, limit: Int) async throws -> [HermesMirrorJobRun] {
        try await dashboard.jobRuns(jobID: jobID, limit: limit)
    }

    func jobRunOutput(jobID: String, runKey: String) async throws -> String? {
        try await dashboard.jobRunOutput(jobID: jobID, runKey: runKey)
    }

    func listFiles(path: String) async throws -> [HermesMirrorFileEntry] {
        try await dashboard.listFiles(path: path)
    }

    func readText(path: String) async throws -> String {
        try await dashboard.readText(path: path)
    }

    func writeText(path: String, content: String) async throws {
        try await dashboard.writeText(path: path, content: content)
    }

    func mkdir(path: String) async throws {
        try await dashboard.mkdir(path: path)
    }

    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage {
        try await dashboard.listSessions(offset: offset, limit: limit)
    }

    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage] {
        try await dashboard.sessionMessages(id: id)
    }
}
