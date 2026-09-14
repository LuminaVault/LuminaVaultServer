import Foundation
import Logging
import LuminaVaultShared

/// BYO transport over the user's own Hermes.
///
/// **The dashboard is optional.** Hermes only accepts a static bearer on the
/// dashboard when it is bound to loopback; a normal public bind offers
/// cookie/PKCE only, so for most self-hosters the dashboard is unreachable to
/// us no matter what token they paste. The gateway `api_server` — which the
/// app already stores a key for — serves skills (`/v1/skills`), cron rows
/// (`/api/jobs`) and sessions (`/api/sessions`), so the reads that make the
/// mirror worth anything work with a gateway alone.
///
/// Where the dashboard *is* usable it is preferred for reads it serves better
/// (skill descriptions and enabled flags). Job mutations go through the
/// gateway `/api/jobs` when no dashboard is linked — `api_server` has create,
/// pause, resume, run and delete. Filesystem access still has no gateway
/// equivalent.
struct RemoteHermesTransport: HermesMirrorTransport {
    let kind: HermesMirrorTransportKind = .remote
    let gatewayBaseURL: URL?
    let gatewayAuthHeader: String?
    let skillsClient: any HermesSkillsClienting
    /// Reads jobs and sessions over the gateway. Present whenever the tenant
    /// has a gateway resolution.
    let gateway: HermesGatewayReadClient?
    let dashboard: HermesDashboardClient?
    let logger: Logger

    /// Dashboard-only operations funnel through this so the failure names the
    /// real constraint instead of looking like a transport bug.
    private func requireDashboard() throws -> HermesDashboardClient {
        guard let dashboard else {
            throw HermesMirrorTransportError.dashboardAuthModeUnsupported
        }
        return dashboard
    }

    func status() async throws -> HermesDashboardStatus {
        if let dashboard {
            return try await dashboard.status()
        }
        // `/api/status` is the dashboard's own public route; without one, report
        // reachability from the gateway resolution we do have.
        return HermesDashboardStatus(reachable: gatewayBaseURL != nil, authRequired: true, version: nil, defaultCwd: nil)
    }

    func listSkills() async throws -> [HermesMirrorSkill] {
        do {
            guard let dashboard else { return try await gatewaySkills() }
            return try await dashboard.listSkills()
        } catch let error as HermesMirrorTransportError {
            guard gatewayBaseURL != nil else { throw error }
            logger.debug("dashboard skills unavailable; falling back to gateway", metadata: ["error": "\(error)"])
            guard let skills = try? await gatewaySkills(), !skills.isEmpty else { throw error }
            return skills
        }
    }

    private func gatewaySkills() async throws -> [HermesMirrorSkill] {
        guard let gatewayBaseURL else { throw HermesMirrorTransportError.unsupported("skills") }
        let entries = await skillsClient.installedSkills(baseURL: gatewayBaseURL, authHeader: gatewayAuthHeader)
        return entries.map { entry in
            HermesMirrorSkill(name: entry.name, description: entry.summary, enabled: true, source: .custom, contentHash: nil)
        }
    }

    func skillContent(name: String) async throws -> String {
        try await requireDashboard().skillContent(name: name)
    }

    func toggleSkill(name: String, enabled: Bool) async throws {
        try await requireDashboard().toggleSkill(name: name, enabled: enabled)
    }

    func createSkill(name: String, content: String) async throws {
        try await requireDashboard().createSkill(name: name, content: content)
    }

    func listJobs() async throws -> [HermesMirrorJob] {
        do {
            guard let dashboard else { return try await requireGateway().listJobs() }
            return try await dashboard.listJobs()
        } catch let error as HermesMirrorTransportError {
            guard let gateway else { throw error }
            logger.debug("dashboard jobs unavailable; falling back to gateway", metadata: ["error": "\(error)"])
            return try await gateway.listJobs()
        }
    }

    private func requireGateway() throws -> HermesGatewayReadClient {
        guard let gateway else { throw HermesMirrorTransportError.unsupported("gateway") }
        return gateway
    }

    func createJob(_ spec: HermesMirrorJobSpec) async throws -> HermesMirrorJob {
        try await withJobWriteFallback("createJob") { dashboard in
            try await dashboard.createJob(spec)
        } gateway: { gateway in
            try await gateway.createJob(spec)
        }
    }

    func updateJob(id: String, updates: HermesMirrorJobUpdate) async throws -> HermesMirrorJob {
        try await withJobWriteFallback("updateJob") { dashboard in
            try await dashboard.updateJob(id: id, updates: updates)
        } gateway: { gateway in
            try await gateway.updateJob(id: id, updates: updates)
        }
    }

    func pauseJob(id: String) async throws -> HermesMirrorJob {
        try await withJobWriteFallback("pauseJob") { dashboard in
            try await dashboard.pauseJob(id: id)
        } gateway: { gateway in
            try await gateway.pauseJob(id: id)
        }
    }

    func resumeJob(id: String) async throws -> HermesMirrorJob {
        try await withJobWriteFallback("resumeJob") { dashboard in
            try await dashboard.resumeJob(id: id)
        } gateway: { gateway in
            try await gateway.resumeJob(id: id)
        }
    }

    func triggerJob(id: String) async throws -> HermesMirrorJob {
        try await withJobWriteFallback("triggerJob") { dashboard in
            try await dashboard.triggerJob(id: id)
        } gateway: { gateway in
            try await gateway.triggerJob(id: id)
        }
    }

    func deleteJob(id: String) async throws {
        do {
            if let dashboard {
                try await dashboard.deleteJob(id: id)
                return
            }
            try await requireGateway().deleteJob(id: id)
        } catch let error as HermesMirrorTransportError {
            guard let gateway else { throw error }
            logger.debug("dashboard deleteJob unavailable; falling back to gateway", metadata: ["error": "\(error)"])
            try await gateway.deleteJob(id: id)
        }
    }

    /// Dashboard first when linked; gateway `/api/jobs` otherwise. A dashboard
    /// that is linked but refuses the write still falls through to the gateway
    /// so a BYO box with a public dashboard (OAuth-only) is not stuck.
    private func withJobWriteFallback(
        _ op: String,
        dashboard performDashboard: (HermesDashboardClient) async throws -> HermesMirrorJob,
        gateway performGateway: (HermesGatewayReadClient) async throws -> HermesMirrorJob
    ) async throws -> HermesMirrorJob {
        do {
            if let dashboard {
                return try await performDashboard(dashboard)
            }
            return try await performGateway(requireGateway())
        } catch let error as HermesMirrorTransportError {
            guard let gateway else { throw error }
            logger.debug(
                "dashboard \(op) unavailable; falling back to gateway",
                metadata: ["error": "\(error)"]
            )
            return try await performGateway(gateway)
        }
    }

    func jobRuns(jobID: String, limit: Int) async throws -> [HermesMirrorJobRun] {
        try await requireDashboard().jobRuns(jobID: jobID, limit: limit)
    }

    func jobRunOutput(jobID: String, runKey: String) async throws -> String? {
        try await requireDashboard().jobRunOutput(jobID: jobID, runKey: runKey)
    }

    func listFiles(path: String) async throws -> [HermesMirrorFileEntry] {
        try await requireDashboard().listFiles(path: path)
    }

    func readText(path: String) async throws -> String {
        try await requireDashboard().readText(path: path)
    }

    func writeText(path: String, content: String) async throws {
        try await requireDashboard().writeText(path: path, content: content)
    }

    func mkdir(path: String) async throws {
        try await requireDashboard().mkdir(path: path)
    }

    func listSessions(offset: Int, limit: Int) async throws -> HermesMirrorSessionPage {
        do {
            guard let dashboard else { return try await requireGateway().listSessions(offset: offset, limit: limit) }
            return try await dashboard.listSessions(offset: offset, limit: limit)
        } catch let error as HermesMirrorTransportError {
            guard let gateway else { throw error }
            return try await gateway.listSessions(offset: offset, limit: limit)
        }
    }

    func sessionMessages(id: String) async throws -> [HermesMirrorSessionMessage] {
        do {
            guard let dashboard else { return try await requireGateway().sessionMessages(id: id) }
            return try await dashboard.sessionMessages(id: id)
        } catch let error as HermesMirrorTransportError {
            guard let gateway else { throw error }
            return try await gateway.sessionMessages(id: id)
        }
    }
}
