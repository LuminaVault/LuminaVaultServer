import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

struct KBCompileController {
    let service: KBCompileService
    let fluent: Fluent
    let achievements: AchievementsService?
    let progress: any KBCompileProgressPublisher
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: compile)
    }

    @Sendable
    func compile(_ req: Request, ctx: AppRequestContext) async throws -> KBCompileResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: KBCompileRequest.self, context: ctx)

        let runId = UUID()
        let rows = try await resolveRows(tenantID: tenantID, body: body)

        await progress.publish(
            .started(.init(runId: runId, totalFiles: rows.count)),
            tenantID: tenantID,
        )

        guard !rows.isEmpty else {
            let empty = KBCompileResponse(memoriesIngested: 0, memoriesUpdated: 0, durationMs: 0, runId: runId)
            await progress.publish(.completed(.init(runId: runId, response: empty)), tenantID: tenantID)
            return empty
        }

        do {
            let started = ContinuousClock.now
            let result = try await service.compileExistingVaultFiles(
                tenantID: tenantID,
                sessionKey: tenantID.uuidString,
                rows: rows,
                hint: nil,
                runId: runId,
            )
            let elapsed = ContinuousClock.now - started
            let elapsedMs = Int(
                elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000,
            )

            try await markFirstKBCompileCompleted(tenantID: tenantID)

            if let achievements {
                Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .kbCompiled) }
            }

            let response = KBCompileResponse(
                memoriesIngested: result.memories.count,
                memoriesUpdated: nil,
                durationMs: elapsedMs,
                runId: runId,
            )
            await progress.publish(.completed(.init(runId: runId, response: response)), tenantID: tenantID)
            return response
        } catch {
            await progress.publish(
                .error(.init(runId: runId, message: "\(error)")),
                tenantID: tenantID,
            )
            throw error
        }
    }

    private func resolveRows(tenantID: UUID, body: KBCompileRequest) async throws -> [VaultFile] {
        let db = fluent.db()
        if let ids = body.vaultFileIds, !ids.isEmpty {
            return try await VaultFile.query(on: db, tenantID: tenantID)
                .filter(\.$id ~~ ids)
                .all()
        }
        if body.forceFullRecompile {
            return try await VaultFile.query(on: db, tenantID: tenantID).all()
        }
        return try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$processedAt == nil)
            .all()
    }

    private func markFirstKBCompileCompleted(tenantID: UUID) async throws {
        let db = fluent.db()
        guard let row = try await OnboardingState.query(on: db, tenantID: tenantID).first(),
              !row.firstKBCompileCompleted
        else { return }
        row.firstKBCompileCompleted = true
        row.firstKBCompileCompletedAt = Date()
        try await row.save(on: db)
    }
}

extension KBCompileResponse: ResponseEncodable {}
