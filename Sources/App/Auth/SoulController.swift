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
    /// P3 — when the tenant routes to a BYO Hermes, SOUL.md lives on their
    /// remote box (file-on-disk, no HTTP write surface — see
    /// docs/hermes-api-server-surface.md). Writing here would only touch the
    /// managed container they never provisioned, so we reject write ops with
    /// a clear error instead of silently no-op'ing. Nil ⇒ managed only.
    let capabilities: HermesRemoteCapabilitiesService?

    init(
        service: SOULService,
        telemetry: RouteTelemetry,
        achievements: AchievementsWorker?,
        capabilities: HermesRemoteCapabilitiesService? = nil
    ) {
        self.service = service
        self.telemetry = telemetry
        self.achievements = achievements
        self.capabilities = capabilities
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: get)
        router.put("", use: put)
        router.post("compose", use: compose)
        router.delete("", use: delete)
    }

    /// Throw a 409 when the tenant is on BYO Hermes and the write can't
    /// reach their box. `get` stays allowed (reads the managed template as a
    /// reference), only mutations are gated.
    private func assertWritableSoul(for user: User) async throws {
        guard let capabilities else { return }
        let tenantID = try user.requireID()
        if await capabilities.isUserOverride(tenantID: tenantID) {
            throw HTTPError(
                .conflict,
                message: "soul_unsupported_on_byo_hermes"
            )
        }
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
        try await assertWritableSoul(for: user)
        let putRequest = try await req.decode(as: SoulPutRequest.self, context: ctx)
        let body = putRequest.markdown
        return try await telemetry.observe("soul.put") {
            let enforced: String
            do {
                // The service strips + re-injects the locked core covenant;
                // echo the enforced document, not the raw client body. The
                // 64 KiB cap applies to the enforced document (core included).
                enforced = try service.write(for: user, body: body)
            } catch let SOULServiceError.tooLarge(bytes, limit) {
                throw HTTPError(
                    .contentTooLarge,
                    message: "SOUL.md too large after core covenant injection: \(bytes) bytes > \(limit)"
                )
            } catch let err as HermesDataError {
                throw HTTPError(.serviceUnavailable, message: err.description)
            }
            if let achievements {
                let tenantID = try user.requireID()
                achievements.enqueue(tenantID: tenantID, event: .soulConfigured)
            }
            return SoulResponse(markdown: enforced, updatedAt: service.updatedAt(for: user))
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
        // `dry_run: true` — onboarding preview: render only, no persistence,
        // no achievement. The client edits the draft and saves via PUT.
        // Allowed for BYO tenants too (pure render, no write).
        if composeRequest.dryRun == true {
            return try await telemetry.observe("soul.compose.dry") {
                SoulResponse(markdown: body, updatedAt: nil)
            }
        }
        try await assertWritableSoul(for: user)
        return try await telemetry.observe("soul.compose") {
            let enforced: String
            do {
                enforced = try service.write(for: user, body: body)
            } catch let SOULServiceError.tooLarge(bytes, limit) {
                throw HTTPError(.contentTooLarge, message: "SOUL.md too large: \(bytes) bytes > \(limit)")
            } catch let err as HermesDataError {
                throw HTTPError(.serviceUnavailable, message: err.description)
            }
            if let achievements {
                let tenantID = try user.requireID()
                achievements.enqueue(tenantID: tenantID, event: .soulConfigured)
            }
            return SoulResponse(markdown: enforced, updatedAt: service.updatedAt(for: user))
        }
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        try await assertWritableSoul(for: user)
        try await telemetry.observe("soul.delete") {
            _ = try service.reset(for: user)
        }
        // openapi: 204 No Content. Client re-fetches to show the reset template.
        return Response(status: .noContent)
    }
}
