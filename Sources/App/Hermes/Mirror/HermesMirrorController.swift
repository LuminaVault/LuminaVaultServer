import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// `/v1/hermes/mirror/*` — the tenant's Hermes mirrored into LuminaVault.
/// JWT + `HermesResolutionMiddleware` + per-user rate limit (wired in
/// `App+build.swift`). Transport errors surface as stable codes
/// (`hermes_dashboard_auth_mode_unsupported`, `hermes_mirror_invalid_path`, …)
/// so clients can render the loopback-behind-proxy fix hint.
struct HermesMirrorController {
    let service: HermesMirrorService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("status", use: status)
        router.post("sync", use: sync)
        router.get("skills", use: skills)
        router.put("skills/:name", use: toggleSkill)
        router.get("jobs", use: jobs)
        router.post("jobs", use: createJob)
        router.post("jobs/install-compile", use: installCompileJob)
        router.get("jobs/:id/runs", use: jobRuns)
        router.put("jobs/:id", use: updateJob)
        router.post("jobs/:id/pause", use: pauseJob)
        router.post("jobs/:id/resume", use: resumeJob)
        router.post("jobs/:id/trigger", use: triggerJob)
        router.delete("jobs/:id", use: deleteJob)
        router.post("jobs/:id/collect", use: collectJobRuns)
        router.post("vault/import", use: importVault)
        router.post("vault/create", use: createVault)
        router.post("vault/import-sessions", use: importSessions)
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> HermesMirrorStatusDTO {
        let tenantID = try ctx.requireTenantID()
        return try await Self.mapErrors { try await service.status(tenantID: tenantID) }
    }

    @Sendable
    func sync(_ req: Request, ctx: AppRequestContext) async throws -> HermesMirrorStatusDTO {
        let tenantID = try ctx.requireTenantID()
        let body = await (try? req.decode(as: HermesMirrorSyncRequest.self, context: ctx)) ?? HermesMirrorSyncRequest()
        let scopes = Set(body.scope ?? HermesMirrorSyncScope.allCases)
        return try await Self.mapErrors { try await service.sync(tenantID: tenantID, scopes: scopes) }
    }

    @Sendable
    func skills(_: Request, ctx: AppRequestContext) async throws -> HermesMirroredSkillsResponse {
        let tenantID = try ctx.requireTenantID()
        return try await Self.mapErrors { try await HermesMirroredSkillsResponse(skills: service.mirroredSkills(tenantID: tenantID)) }
    }

    @Sendable
    func toggleSkill(_ req: Request, ctx: AppRequestContext) async throws -> HermesMirroredSkillDTO {
        let tenantID = try ctx.requireTenantID()
        guard let name = ctx.parameters.get("name"), !name.isEmpty else {
            throw HTTPError(.badRequest, message: "skill_name_required")
        }
        let body = try await req.decode(as: HermesMirroredSkillToggleRequest.self, context: ctx)
        return try await Self.mapErrors { try await service.toggleSkill(tenantID: tenantID, name: String(name), enabled: body.enabled) }
    }

    @Sendable
    func jobs(_: Request, ctx: AppRequestContext) async throws -> HermesMirroredJobsResponse {
        let tenantID = try ctx.requireTenantID()
        return try await Self.mapErrors { try await service.jobs(tenantID: tenantID) }
    }

    /// Pull this job's finished runs now instead of waiting for the worker
    /// tick. Idempotent — already-collected runs are skipped by run key.
    @Sendable
    func collectJobRuns(_: Request, ctx: AppRequestContext) async throws -> HermesJobCollectResultDTO {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        return try await Self.mapErrors { try await service.collectJobRuns(tenantID: tenantID, jobID: jobID) }
    }

    static func jobID(_ ctx: AppRequestContext) throws -> String {
        guard let raw = ctx.parameters.get("id"), !raw.isEmpty else {
            throw HTTPError(.badRequest, message: "hermes_job_id_required")
        }
        return String(raw)
    }

    // MARK: - Job control

    /// Runs LuminaVault has already collected for this job, newest first.
    /// Reads stored rows only — it never touches the tenant's Hermes, so it
    /// answers while that Hermes is offline.
    @Sendable
    func jobRuns(_ req: Request, ctx: AppRequestContext) async throws -> HermesJobRunsResponse {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        let limit = req.uri.queryParameters["limit"].flatMap { Int(String($0)) } ?? HermesMirrorService.defaultJobRunsLimit
        return try await Self.mapErrors {
            try await service.jobRuns(tenantID: tenantID, jobID: jobID, limit: limit)
        }
    }

    /// Creates a cron job on the tenant's Hermes (full `CronJobCreate` body).
    @Sendable
    func createJob(_ req: Request, ctx: AppRequestContext) async throws -> HermesMirroredJobDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: HermesJobCreateRequest.self, context: ctx)
        return try await Self.mapErrors { try await service.createJob(tenantID: tenantID, request: body) }
    }

    @Sendable
    func updateJob(_ req: Request, ctx: AppRequestContext) async throws -> HermesMirroredJobDTO {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        let body = try await req.decode(as: HermesJobUpdateRequest.self, context: ctx)
        return try await Self.mapErrors { try await service.updateJob(tenantID: tenantID, jobID: jobID, request: body) }
    }

    @Sendable
    func pauseJob(_: Request, ctx: AppRequestContext) async throws -> HermesMirroredJobDTO {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        return try await Self.mapErrors { try await service.pauseJob(tenantID: tenantID, jobID: jobID) }
    }

    @Sendable
    func resumeJob(_: Request, ctx: AppRequestContext) async throws -> HermesMirroredJobDTO {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        return try await Self.mapErrors { try await service.resumeJob(tenantID: tenantID, jobID: jobID) }
    }

    @Sendable
    func triggerJob(_: Request, ctx: AppRequestContext) async throws -> HermesMirroredJobDTO {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        return try await Self.mapErrors { try await service.triggerJob(tenantID: tenantID, jobID: jobID) }
    }

    @Sendable
    func deleteJob(_: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        let tenantID = try ctx.requireTenantID()
        let jobID = try Self.jobID(ctx)
        try await Self.mapErrors { try await service.deleteJob(tenantID: tenantID, jobID: jobID) }
        return .noContent
    }

    @Sendable
    func installCompileJob(_: Request, ctx: AppRequestContext) async throws -> HermesCompileJobInstallResultDTO {
        let tenantID = try ctx.requireTenantID()
        return try await Self.mapErrors { try await service.installCompileJob(tenantID: tenantID) }
    }

    @Sendable
    func importVault(_ req: Request, ctx: AppRequestContext) async throws -> HermesVaultImportResultDTO {
        let tenantID = try ctx.requireTenantID()
        let body = await (try? req.decode(as: HermesVaultImportRequest.self, context: ctx)) ?? HermesVaultImportRequest()
        let requested = body.vaultPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await Self.mapErrors {
            try await service.importVault(tenantID: tenantID, requestedPath: (requested?.isEmpty == false) ? requested : nil)
        }
    }

    @Sendable
    func createVault(_: Request, ctx: AppRequestContext) async throws -> HermesVaultCreateResultDTO {
        let tenantID = try ctx.requireTenantID()
        return try await Self.mapErrors { try await service.createVault(tenantID: tenantID) }
    }

    @Sendable
    func importSessions(_: Request, ctx: AppRequestContext) async throws -> HermesSessionsImportResultDTO {
        let tenantID = try ctx.requireTenantID()
        return try await Self.mapErrors { try await service.importSessions(tenantID: tenantID) }
    }

    /// Transport errors → stable HTTP codes. Upstream bodies are never forwarded.
    static func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HermesMirrorTransportError {
            throw HTTPError(status(for: error), message: error.code)
        }
    }

    static func status(for error: HermesMirrorTransportError) -> HTTPResponse.Status {
        switch error {
        case .invalidPath, .bodyTooLarge: .badRequest
        case .notFound: .notFound
        case .notConfigured: .conflict
        case .unsupported: .notImplemented
        case .http, .invalidResponse, .dashboardAuthModeUnsupported, .dashboardUnauthorized, .dashboardUnreachable: .badGateway
        }
    }
}

extension HermesMirrorStatusDTO: ResponseEncodable {}
extension HermesMirroredSkillsResponse: ResponseEncodable {}
extension HermesMirroredSkillDTO: ResponseEncodable {}
extension HermesMirroredJobsResponse: ResponseEncodable {}
extension HermesMirroredJobDTO: ResponseEncodable {}
extension HermesJobRunsResponse: ResponseEncodable {}
extension HermesCompileJobInstallResultDTO: ResponseEncodable {}
extension HermesVaultImportResultDTO: ResponseEncodable {}
extension HermesVaultCreateResultDTO: ResponseEncodable {}
extension HermesSessionsImportResultDTO: ResponseEncodable {}
extension HermesJobCollectResultDTO: ResponseEncodable {}

/// Builds the mirror stack from the BYO-Hermes dependencies so `App+build`
/// stays to a few lines.
enum HermesMirrorWiring {
    struct Dependencies {
        let fluent: HummingbirdFluent.Fluent
        let secretBox: SecretBox
        let ssrfGuard: SSRFGuard
        let resolver: HermesEndpointResolver
        let capabilities: HermesRemoteCapabilitiesService?
        let containerManager: HermesContainerManager?
        let perTenantDataRootBase: String
        let managedHermesRoot: String
        let ingest: VaultIngestService
        let compileController: MemoryCompileController
        let logger: Logger
    }

    struct Built {
        let service: HermesMirrorService
        let controller: HermesMirrorController
        /// Rotate + read on the mirror group; the push route goes on the root
        /// router (`addPublicRoutes`) because the sender is the user's Hermes.
        let webhooks: HermesMirrorWebhookController
    }

    static func make(_ deps: Dependencies) -> Built {
        let transports = HermesMirrorTransportFactory(
            credentials: HermesDashboardCredentialStore(fluent: deps.fluent, secretBox: deps.secretBox),
            ssrfGuard: deps.ssrfGuard,
            resolver: deps.resolver,
            skillsClient: HermesSkillsClient(logger: deps.logger),
            http: AsyncHTTPClientHermesHTTP(),
            containerManager: deps.containerManager,
            perTenantDataRootBase: deps.perTenantDataRootBase,
            managedHermesRoot: deps.managedHermesRoot,
            logger: deps.logger
        )
        let service = HermesMirrorService(
            fluent: deps.fluent,
            transports: transports,
            capabilities: deps.capabilities,
            ingest: deps.ingest,
            compile: MemoryCompileControllerRunner(controller: deps.compileController, fluent: deps.fluent),
            logger: deps.logger
        )
        return Built(
            service: service,
            controller: HermesMirrorController(service: service),
            webhooks: HermesMirrorWebhookController(
                fluent: deps.fluent,
                secretBox: deps.secretBox,
                service: service,
                logger: deps.logger
            )
        )
    }
}
