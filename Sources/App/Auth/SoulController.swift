import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension SoulResponse: @retroactive ResponseEncodable {}

/// HER-85: SOUL.md CRUD surface.
///
/// Mounted under `/v1/soul`, behind JWT. Per-route rate-limit is added at
/// wiring time (see `App+build.swift`).
struct SoulController {
    let service: SOULService
    let telemetry: RouteTelemetry
    let achievements: AchievementsWorker?

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: get)
        router.put("", use: put)
        router.post("compose", use: compose)
        router.delete("", use: delete)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        return try await telemetry.observe("soul.get") {
            let body = try service.read(for: user)
            return SoulResponse(markdown: body, updatedAt: service.updatedAt(for: user))
        }
    }

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        // Canonical contract (openapi `SoulPutRequest`): JSON `{ markdown }`.
        // The 64 KiB cap is enforced by `SOULService.write`.
        let putRequest = try await req.decode(as: SoulPutRequest.self, context: ctx)
        let body = putRequest.markdown
        return try await telemetry.observe("soul.put") {
            do {
                try service.write(for: user, body: body)
            } catch let SOULServiceError.tooLarge(bytes, limit) {
                throw HTTPError(.contentTooLarge, message: "SOUL.md too large: \(bytes) bytes > \(limit)")
            }
            if let achievements {
                let tenantID = try user.requireID()
                achievements.enqueue(tenantID: tenantID, event: .soulConfigured)
            }
            return SoulResponse(markdown: body, updatedAt: service.updatedAt(for: user))
        }
    }

    @Sendable
    func compose(_ req: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        // Canonical contract (openapi `SoulComposeRequest`): structured fields
        // are rendered into a deterministic, fully-filled SOUL.md (no template
        // comments). Persisted via the same path as `put`; 64 KiB cap applies.
        let composeRequest = try await req.decode(as: SoulComposeRequest.self, context: ctx)
        let body = SOULComposer.render(composeRequest, username: user.username)
        return try await telemetry.observe("soul.compose") {
            do {
                try service.write(for: user, body: body)
            } catch let SOULServiceError.tooLarge(bytes, limit) {
                throw HTTPError(.contentTooLarge, message: "SOUL.md too large: \(bytes) bytes > \(limit)")
            }
            if let achievements {
                let tenantID = try user.requireID()
                achievements.enqueue(tenantID: tenantID, event: .soulConfigured)
            }
            return SoulResponse(markdown: body, updatedAt: service.updatedAt(for: user))
        }
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        try await telemetry.observe("soul.delete") {
            _ = try service.reset(for: user)
        }
        // openapi: 204 No Content. Client re-fetches to show the reset template.
        return Response(status: .noContent)
    }
}
