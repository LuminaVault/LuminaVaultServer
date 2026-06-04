import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension HermesGatewayCatalogEntry: @retroactive ResponseEncodable {}
extension HermesGatewaysListResponse: @retroactive ResponseEncodable {}
extension HermesGatewayTestResponse: @retroactive ResponseEncodable {}
extension HermesGatewayApplyJobStatus: @retroactive ResponseEncodable {}
extension StartHermesGatewayApplyResponse: @retroactive ResponseEncodable {}
extension StartWhatsAppPairResponse: @retroactive ResponseEncodable {}

/// HER-241 — `/v1/me/hermes-gateways` GET / GET-one / PUT / DELETE /
/// POST-test.
///
/// Hermes itself exposes no gateway-admin HTTP endpoints today
/// (`hermes gateway setup` is CLI-only). This controller therefore:
///
///   1. Persists per-user gateway config encrypted via `SecretBox`
///      (`config_ciphertext` + `config_nonce`).
///   2. Reports per-gateway status by joining the static
///      `HermesGatewayCatalog` against the user's rows.
///   3. Probes the user's Hermes `/v1/health` on `POST .../{id}/test`
///      and stamps `verified_at` on success. Status never advances
///      past `.configured` (Hermes can't yet confirm a gateway is
///      actually live over HTTP).
///
/// Plaintext config is never echoed: list/get responses carry
/// `hasConfig: Bool` only. When upstream ships a real admin API,
/// `HermesGatewayClient.health(...)` is the swap point — controller
/// and DTO contracts stay frozen.
struct HermesGatewaysController {
    enum ErrorCode: String {
        case missingField = "missing_field"
        case unsupportedGateway = "unsupported_gateway"
        case encryptionFailed = "encryption_failed"
        case decryptionFailed = "decryption_failed"
        case hermesNotConfigured = "hermes_not_configured"
    }

    let fluent: Fluent
    let secretBox: SecretBox
    let gatewayClient: any HermesGatewayClienting
    /// Drives the "apply gateway config" actuation flow (re-seed `.env` +
    /// restart the tenant container) with live SSE progress. `nil` when
    /// per-tenant containers are disabled — the apply routes then 404.
    let applyService: HermesGatewayApplyService?
    /// Drives WhatsApp QR pairing (run `hermes whatsapp`, stream the QR, detect
    /// link, unlink). `nil` when per-tenant containers are disabled — the
    /// WhatsApp routes then 404.
    let whatsAppPairingService: WhatsAppPairingService?
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: list)
        // WhatsApp QR pairing (literal paths registered before `:id` catch-alls).
        router.post("whatsapp/pair", use: whatsAppStartPair)
        router.get("whatsapp/pair/:sessionID/stream", use: whatsAppPairStream)
        router.delete("whatsapp/session", use: whatsAppUnlink)
        router.get(":id", use: getOne)
        router.put(":id", use: put)
        router.delete(":id", use: delete)
        router.post(":id/test", use: test)
        // Actuation: apply all configured gateways to the running container.
        router.post("apply", use: apply)
        router.get("apply/current", use: applyCurrent)
        router.get("apply/:jobID", use: applyStatus)
        router.get("apply/:jobID/stream", use: applyStream)
    }

    // MARK: - GET /v1/me/hermes-gateways

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> HermesGatewaysListResponse {
        let tenantID = try ctx.requireTenantID()
        let rows = try await UserHermesGateway.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        var byID: [String: UserHermesGateway] = [:]
        for row in rows {
            byID[row.gatewayID] = row
        }

        // Surface every catalog gateway in `HermesGatewayID.allCases` order.
        // WhatsApp is a pairing gateway — its status comes from whether a
        // session is persisted (via the pairing service), not a credential row.
        var entries: [HermesGatewayCatalogEntry] = []
        for id in HermesGatewayID.allCases where HermesGatewayCatalog.entries[id] != nil {
            await entries.append(entryDTO(for: id, tenantID: tenantID, row: byID[id.rawValue]))
        }
        return HermesGatewaysListResponse(items: entries)
    }

    // MARK: - GET /v1/me/hermes-gateways/{id}

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayCatalogEntry {
        let tenantID = try ctx.requireTenantID()
        let id = try parseID(ctx)
        let row = try await loadRow(tenantID: tenantID, gatewayID: id)
        return await entryDTO(for: id, tenantID: tenantID, row: row)
    }

    /// Build the catalog-entry DTO for one gateway. Credential gateways derive
    /// status from their `UserHermesGateway` row; pairing gateways (WhatsApp)
    /// derive it from a persisted session via the pairing service.
    private func entryDTO(
        for id: HermesGatewayID,
        tenantID: UUID,
        row: UserHermesGateway?,
    ) async -> HermesGatewayCatalogEntry {
        let entry = HermesGatewayCatalog.entry(for: id)
        let status: HermesGatewayStatus
        let hasConfig: Bool
        if entry.pairingKind != nil {
            let paired = await whatsAppPairingService?.isPaired(tenantID: tenantID) ?? false
            status = paired ? .verified : .notConfigured
            hasConfig = paired
        } else {
            status = row.flatMap { HermesGatewayStatus(rawValue: $0.status) } ?? .notConfigured
            hasConfig = row != nil
        }
        return HermesGatewayCatalogEntry(
            id: id,
            displayName: entry.displayName,
            iconSlug: entry.iconSlug,
            description: entry.description,
            requiredFields: entry.requiredFields,
            status: status,
            hasConfig: hasConfig,
            verifiedAt: row?.verifiedAt,
            lastFailureCode: row?.lastFailureCode,
            pairingKind: entry.pairingKind,
        )
    }

    // MARK: - PUT /v1/me/hermes-gateways/{id}

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> HermesGatewayCatalogEntry {
        let tenantID = try ctx.requireTenantID()
        let id = try parseID(ctx)
        try rejectPairingGateway(id)
        let body = try await req.decode(as: HermesGatewayPutRequest.self, context: ctx)

        switch HermesGatewayCatalog.validate(id, config: body.config) {
        case .ok: break
        case let .missing(key):
            throw HTTPError(.badRequest, message: "\(ErrorCode.missingField.rawValue):\(key)")
        }

        let plaintext = try encodeConfig(body.config)
        let sealed: SecretBox.Sealed
        do {
            sealed = try secretBox.seal(plaintext, tenantID: tenantID)
        } catch {
            logger.error("hermes gateway config encryption failed: \(error)")
            throw HTTPError(.internalServerError, message: ErrorCode.encryptionFailed.rawValue)
        }

        let existing = try await loadRow(tenantID: tenantID, gatewayID: id)
        let row: UserHermesGateway
        if let existing {
            row = existing
        } else {
            row = UserHermesGateway()
            row.tenantID = tenantID
            row.gatewayID = id.rawValue
        }
        row.configCiphertext = sealed.ciphertext
        row.configNonce = sealed.nonce
        row.status = HermesGatewayStatus.configured.rawValue
        row.verifiedAt = nil
        row.lastFailureAt = nil
        row.lastFailureCode = nil
        try await row.save(on: fluent.db())

        let entry = HermesGatewayCatalog.entry(for: id)
        return HermesGatewayCatalogEntry(
            id: id,
            displayName: entry.displayName,
            iconSlug: entry.iconSlug,
            description: entry.description,
            requiredFields: entry.requiredFields,
            status: .configured,
            hasConfig: true,
            verifiedAt: nil,
            lastFailureCode: nil,
        )
    }

    // MARK: - DELETE /v1/me/hermes-gateways/{id}

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let id = try parseID(ctx)
        try rejectPairingGateway(id) // WhatsApp uses DELETE .../whatsapp/session
        try await UserHermesGateway.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$gatewayID == id.rawValue)
            .delete()
        return Response(status: .noContent)
    }

    // MARK: - POST /v1/me/hermes-gateways/{id}/test

    @Sendable
    func test(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayTestResponse {
        let tenantID = try ctx.requireTenantID()
        let id = try parseID(ctx)
        try rejectPairingGateway(id)

        guard let resolution = ctx.hermesResolution else {
            throw HTTPError(.badRequest, message: ErrorCode.hermesNotConfigured.rawValue)
        }

        let result = await gatewayClient.health(
            baseURL: resolution.baseURL,
            authHeader: resolution.authHeader,
        )

        let row = try await loadRow(tenantID: tenantID, gatewayID: id)
        switch result {
        case .reachable:
            if let row {
                row.verifiedAt = Date()
                row.lastFailureAt = nil
                row.lastFailureCode = nil
                try await row.save(on: fluent.db())
            }
            return HermesGatewayTestResponse(
                ok: true,
                verifiedAt: row?.verifiedAt ?? Date(),
            )
        case .unauthorized, .unreachable:
            let code = result.errorCode ?? "unknown"
            if let row {
                row.lastFailureAt = Date()
                row.lastFailureCode = code
                try await row.save(on: fluent.db())
            }
            return HermesGatewayTestResponse(
                ok: false,
                errorCode: code,
                errorMessage: nil,
            )
        }
    }

    // MARK: - POST /v1/me/hermes-gateways/apply

    @Sendable
    func apply(_: Request, ctx: AppRequestContext) async throws -> StartHermesGatewayApplyResponse {
        let tenantID = try ctx.requireTenantID()
        let service = try requireApplyService()
        do {
            let snapshot = try await service.startApply(tenantID: tenantID)
            return StartHermesGatewayApplyResponse(jobID: snapshot.jobID, state: snapshot.state)
        } catch HermesGatewayApplyError.alreadyRunning {
            throw HTTPError(.conflict, message: "apply_in_progress")
        }
    }

    // MARK: - GET /v1/me/hermes-gateways/apply/current

    @Sendable
    func applyCurrent(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayApplyJobStatus {
        let tenantID = try ctx.requireTenantID()
        let service = try requireApplyService()
        guard let snapshot = try await service.currentJob(tenantID: tenantID) else {
            throw HTTPError(.notFound, message: "no_apply_job")
        }
        return snapshot
    }

    // MARK: - GET /v1/me/hermes-gateways/apply/:jobID

    @Sendable
    func applyStatus(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayApplyJobStatus {
        let tenantID = try ctx.requireTenantID()
        let service = try requireApplyService()
        let jobID = try requireJobID(ctx)
        guard let snapshot = try await service.job(id: jobID, tenantID: tenantID) else {
            throw HTTPError(.notFound, message: "job_not_found")
        }
        return snapshot
    }

    // MARK: - GET /v1/me/hermes-gateways/apply/:jobID/stream (SSE)

    @Sendable
    func applyStream(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayApplySSEResponse {
        let tenantID = try ctx.requireTenantID()
        let service = try requireApplyService()
        let jobID = try requireJobID(ctx)
        // 404 early (tenant-scoped) so the client doesn't open a long-lived
        // stream against a typo or another tenant's job.
        guard try await service.job(id: jobID, tenantID: tenantID) != nil else {
            throw HTTPError(.notFound, message: "job_not_found")
        }
        return await HermesGatewayApplySSEResponse(events: service.subscribe(jobID: jobID, tenantID: tenantID))
    }

    // MARK: - POST /v1/me/hermes-gateways/whatsapp/pair

    @Sendable
    func whatsAppStartPair(_: Request, ctx: AppRequestContext) async throws -> StartWhatsAppPairResponse {
        let tenantID = try ctx.requireTenantID()
        let service = try requireWhatsAppService()
        let sessionID = try await service.startPairing(tenantID: tenantID)
        return StartWhatsAppPairResponse(sessionID: sessionID)
    }

    // MARK: - GET /v1/me/hermes-gateways/whatsapp/pair/:sessionID/stream (SSE)

    @Sendable
    func whatsAppPairStream(_: Request, ctx: AppRequestContext) async throws -> WhatsAppPairSSEResponse {
        _ = try ctx.requireTenantID()
        let service = try requireWhatsAppService()
        guard let sessionID = ctx.parameters.get("sessionID", as: UUID.self) else {
            throw HTTPError(.badRequest, message: "invalid_session_id")
        }
        return await WhatsAppPairSSEResponse(events: service.subscribe(sessionID: sessionID))
    }

    // MARK: - DELETE /v1/me/hermes-gateways/whatsapp/session

    @Sendable
    func whatsAppUnlink(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayCatalogEntry {
        let tenantID = try ctx.requireTenantID()
        let service = try requireWhatsAppService()
        _ = try await service.unlink(tenantID: tenantID)
        return await entryDTO(for: .whatsapp, tenantID: tenantID, row: nil)
    }

    // MARK: - Helpers

    private func requireWhatsAppService() throws -> WhatsAppPairingService {
        guard let whatsAppPairingService else {
            throw HTTPError(.notFound, message: "whatsapp_pairing_unavailable")
        }
        return whatsAppPairingService
    }

    /// Reject credential routes (PUT/DELETE/test) for pairing gateways like
    /// WhatsApp, which has no enterable credential.
    private func rejectPairingGateway(_ id: HermesGatewayID) throws {
        if HermesGatewayCatalog.entry(for: id).pairingKind != nil {
            throw HTTPError(.badRequest, message: ErrorCode.unsupportedGateway.rawValue)
        }
    }

    private func requireApplyService() throws -> HermesGatewayApplyService {
        guard let applyService else {
            throw HTTPError(.notFound, message: "apply_unavailable")
        }
        return applyService
    }

    private func requireJobID(_ ctx: AppRequestContext) throws -> UUID {
        guard let jobID = ctx.parameters.get("jobID", as: UUID.self) else {
            throw HTTPError(.badRequest, message: "invalid_job_id")
        }
        return jobID
    }

    private func parseID(_ ctx: AppRequestContext) throws -> HermesGatewayID {
        let raw = try ctx.parameters.require("id", as: String.self)
        // Must be a known enum case AND present in the catalog (excludes
        // WhatsApp, which isn't remotely configurable — keeps `entry(for:)`'s
        // force-unwrap safe).
        guard let id = HermesGatewayID(rawValue: raw),
              HermesGatewayCatalog.entries[id] != nil
        else {
            throw HTTPError(.notFound, message: ErrorCode.unsupportedGateway.rawValue)
        }
        return id
    }

    private func loadRow(tenantID: UUID, gatewayID: HermesGatewayID) async throws -> UserHermesGateway? {
        try await UserHermesGateway.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$gatewayID == gatewayID.rawValue)
            .first()
    }

    /// Serialize the config dict to JSON for SecretBox sealing. Sorted
    /// keys keep ciphertext deterministic for the same input — useful
    /// for debugging, never for crypto (the nonce is fresh per call).
    private func encodeConfig(_ config: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        return String(decoding: data, as: UTF8.self)
    }
}
