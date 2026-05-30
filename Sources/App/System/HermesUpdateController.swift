import Foundation
import Hummingbird
import LuminaVaultShared
import Logging

/// HER-330 — owner-facing "Update Hermes" routes under `/v1/system/hermes`.
///
/// The route group is gated by **both** the JWT authenticator (authenticated
/// owner) and `AdminTokenMiddleware` (the server's shared admin secret),
/// wired in `App+build.swift`. Because the group already enforces auth, the
/// handlers themselves only orchestrate.
struct HermesUpdateController {
    let service: HermesUpdateService
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("version", use: version)
        router.post("update", use: startUpdate)
        router.get("update/current", use: currentJob)
        router.get("update/:jobID", use: jobStatus)
        router.get("update/:jobID/stream", use: stream)
        router.post("update/:jobID/rollback", use: rollback)
    }

    // MARK: - GET /version

    @Sendable
    func version(_: Request, ctx _: AppRequestContext) async throws -> HermesVersionInfoResponse {
        HermesVersionInfoResponse(info: await service.currentVersionInfo())
    }

    // MARK: - POST /update

    @Sendable
    func startUpdate(_ req: Request, ctx: AppRequestContext) async throws -> StartHermesUpdateResponseBody {
        let body = (try? await req.decode(as: StartHermesUpdateRequest.self, context: ctx))
            ?? StartHermesUpdateRequest(targetTag: nil)
        do {
            let snapshot = try await service.startUpdate(targetTag: body.targetTag)
            return StartHermesUpdateResponseBody(jobID: snapshot.jobID, state: snapshot.state)
        } catch HermesUpdateError.alreadyRunning {
            throw HTTPError(.conflict, message: "update_in_progress")
        }
    }

    // MARK: - GET /update/current

    @Sendable
    func currentJob(_: Request, ctx _: AppRequestContext) async throws -> HermesUpdateJobStatusResponse {
        guard let snapshot = try await service.currentJob() else {
            throw HTTPError(.notFound, message: "no_update_job")
        }
        return HermesUpdateJobStatusResponse(status: snapshot)
    }

    // MARK: - GET /update/:jobID

    @Sendable
    func jobStatus(_: Request, ctx: AppRequestContext) async throws -> HermesUpdateJobStatusResponse {
        let jobID = try requireJobID(ctx)
        guard let snapshot = try await service.job(id: jobID) else {
            throw HTTPError(.notFound, message: "job_not_found")
        }
        return HermesUpdateJobStatusResponse(status: snapshot)
    }

    // MARK: - GET /update/:jobID/stream (SSE)

    @Sendable
    func stream(_: Request, ctx: AppRequestContext) async throws -> HermesUpdateSSEResponse {
        let jobID = try requireJobID(ctx)
        // 404 early if the job doesn't exist, so the client doesn't open a
        // long-lived stream against a typo.
        guard try await service.job(id: jobID) != nil else {
            throw HTTPError(.notFound, message: "job_not_found")
        }
        return HermesUpdateSSEResponse(events: await service.subscribe(jobID: jobID))
    }

    // MARK: - POST /update/:jobID/rollback

    @Sendable
    func rollback(_: Request, ctx: AppRequestContext) async throws -> StartHermesUpdateResponseBody {
        let jobID = try requireJobID(ctx)
        do {
            let snapshot = try await service.startRollback(forJobID: jobID)
            return StartHermesUpdateResponseBody(jobID: snapshot.jobID, state: snapshot.state)
        } catch HermesUpdateError.alreadyRunning {
            throw HTTPError(.conflict, message: "update_in_progress")
        } catch let HermesUpdateError.rollbackFailed(reason) {
            throw HTTPError(.badRequest, message: "rollback_unavailable:\(reason)")
        }
    }

    // MARK: - Helpers

    private func requireJobID(_ ctx: AppRequestContext) throws -> UUID {
        guard let jobID = ctx.parameters.get("jobID", as: UUID.self) else {
            throw HTTPError(.badRequest, message: "invalid_job_id")
        }
        return jobID
    }
}

// MARK: - Response envelopes
//
// Thin `ResponseEncodable` wrappers around the shared wire DTOs. The DTOs
// live in `LuminaVaultShared`; these envelopes are server-only glue so the
// handlers can return Hummingbird-encodable values.

struct HermesVersionInfoResponse: Codable, ResponseEncodable {
    let info: HermesVersionInfo
}

struct HermesUpdateJobStatusResponse: Codable, ResponseEncodable {
    let status: HermesUpdateJobStatus
}

struct StartHermesUpdateResponseBody: Codable, ResponseEncodable {
    let jobID: UUID
    let state: HermesUpdateJobState
}
