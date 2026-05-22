import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension HermesGatewayCatalogEntry: ResponseEncodable {}
extension HermesGatewaysListResponse: ResponseEncodable {}
extension HermesGatewayTestResponse: ResponseEncodable {}

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
    let logger: Logger

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        gatewayClient: any HermesGatewayClienting,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.gatewayClient = gatewayClient
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: list)
        router.get(":id", use: getOne)
        router.put(":id", use: put)
        router.delete(":id", use: delete)
        router.post(":id/test", use: test)
    }

    // MARK: - GET /v1/me/hermes-gateways

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> HermesGatewaysListResponse {
        let tenantID = try ctx.requireTenantID()
        let rows = try await UserHermesGateway.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        var byID: [String: UserHermesGateway] = [:]
        for row in rows { byID[row.gatewayID] = row }

        let entries = HermesGatewayID.allCases.map { id -> HermesGatewayCatalogEntry in
            let entry = HermesGatewayCatalog.entry(for: id)
            let row = byID[id.rawValue]
            return HermesGatewayCatalogEntry(
                id: id,
                displayName: entry.displayName,
                iconSlug: entry.iconSlug,
                description: entry.description,
                requiredFields: entry.requiredFields,
                status: row.flatMap { HermesGatewayStatus(rawValue: $0.status) } ?? .notConfigured,
                hasConfig: row != nil,
                verifiedAt: row?.verifiedAt,
                lastFailureCode: row?.lastFailureCode,
            )
        }
        return HermesGatewaysListResponse(items: entries)
    }

    // MARK: - GET /v1/me/hermes-gateways/{id}

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> HermesGatewayCatalogEntry {
        let tenantID = try ctx.requireTenantID()
        let id = try parseID(ctx)
        let row = try await loadRow(tenantID: tenantID, gatewayID: id)
        let entry = HermesGatewayCatalog.entry(for: id)
        return HermesGatewayCatalogEntry(
            id: id,
            displayName: entry.displayName,
            iconSlug: entry.iconSlug,
            description: entry.description,
            requiredFields: entry.requiredFields,
            status: row.flatMap { HermesGatewayStatus(rawValue: $0.status) } ?? .notConfigured,
            hasConfig: row != nil,
            verifiedAt: row?.verifiedAt,
            lastFailureCode: row?.lastFailureCode,
        )
    }

    // MARK: - PUT /v1/me/hermes-gateways/{id}

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> HermesGatewayCatalogEntry {
        let tenantID = try ctx.requireTenantID()
        let id = try parseID(ctx)
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

    // MARK: - Helpers

    private func parseID(_ ctx: AppRequestContext) throws -> HermesGatewayID {
        let raw = try ctx.parameters.require("id", as: String.self)
        guard let id = HermesGatewayID(rawValue: raw) else {
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
