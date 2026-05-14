import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension SoulResponse: ResponseEncodable {}

/// HER-85: SOUL.md CRUD surface.
///
/// Mounted under `/v1/soul`, behind JWT. Per-route rate-limit is added at
/// wiring time (see `App+build.swift`).
struct SoulController {
    let service: SOULService
    let telemetry: RouteTelemetry
    let achievements: AchievementsService?

    /// Cap matches `SOULService.maxSizeBytes`; here we collect at most that
    /// many bytes from the request before failing fast.
    private let maxBodyBytes = SOULService.maxSizeBytes

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: get)
        router.put("", use: put)
        router.delete("", use: delete)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        return try await telemetry.observe("soul.get") {
            let body = try service.read(for: user)
            return SoulResponse(content: body, sizeBytes: body.lengthOfBytes(using: .utf8))
        }
    }

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        var mutableRequest = req
        let buffer = try await mutableRequest.collectBody(upTo: maxBodyBytes)
        let data = Data(buffer: buffer)
        guard let body = String(data: data, encoding: .utf8) else {
            throw HTTPError(.badRequest, message: "body must be UTF-8 text")
        }
        return try await telemetry.observe("soul.put") {
            do {
                try service.write(for: user, body: body)
            } catch let SOULServiceError.tooLarge(bytes, limit) {
                throw HTTPError(.contentTooLarge, message: "SOUL.md too large: \(bytes) bytes > \(limit)")
            }
            if let achievements {
                let tenantID = try user.requireID()
                Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .soulConfigured) }
            }
            return SoulResponse(content: body, sizeBytes: body.lengthOfBytes(using: .utf8))
        }
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        return try await telemetry.observe("soul.delete") {
            let body = try service.reset(for: user)
            return SoulResponse(content: body, sizeBytes: body.lengthOfBytes(using: .utf8))
        }
    }
}
