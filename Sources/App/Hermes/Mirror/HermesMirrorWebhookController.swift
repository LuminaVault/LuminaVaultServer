import Crypto
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension HermesMirrorWebhookDTO: @retroactive ResponseEncodable {}

/// Hermes Mirror Phase 2 — the optional inbound push.
///
/// The tenant's Hermes posts to `/v1/hermes/mirror/webhook/<token>` when one
/// of its cron jobs finishes and LuminaVault collects that job immediately
/// instead of waiting for the next worker tick. **Pull stays the source of
/// truth.** A webhook that is never configured, never arrives, arrives late,
/// arrives twice or fails outright must leave collection exactly as correct
/// as it was — the poll and the push run the same idempotent pass, keyed on
/// Hermes' own run key, so the only thing the push changes is latency.
///
/// That is also why a failed collect here is not an error to the sender:
/// answering 500 would invite a Hermes-side retry loop over work the poller
/// will do anyway.
///
/// The route is unauthenticated by construction — the tenant's Hermes has no
/// LuminaVault session — so the token in the path plus an HMAC over
/// `<timestamp>.<body>` is the whole gate. Unknown token, bad signature and a
/// stale or missing timestamp all answer the same 401 with the same message:
/// a sender that can tell "wrong signature" from "no such token" can probe
/// for live tokens.
struct HermesMirrorWebhookController {
    /// Same envelope the workflow hooks use (`X-Webhook-Signature-V2` over
    /// `<unix seconds>.<raw body>`), so a user wiring both speaks one scheme.
    static let signatureHeader = "X-Webhook-Signature-V2"
    static let timestampHeader = "X-Webhook-Timestamp"
    static let replayWindow: TimeInterval = 300
    static let maxBodyBytes = 1024 * 1024
    static let routePrefix = "/v1/hermes/mirror/webhook"

    let fluent: Fluent
    let secretBox: SecretBox
    let service: HermesMirrorService
    let logger: Logger
    let clock: @Sendable () -> Date

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        service: HermesMirrorService,
        logger: Logger,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.service = service
        self.logger = logger
        self.clock = clock
    }

    /// JWT-gated half: read the current credential, or rotate it.
    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("webhook", use: current)
        router.post("webhook", use: rotate)
    }

    /// The push endpoint itself. Registered on the root router, not the
    /// mirror group, because the sender is the user's Hermes and carries no
    /// LuminaVault credentials.
    func addPublicRoutes(to router: Router<AppRequestContext>) {
        router.post("\(Self.routePrefix)/:token", use: ingest)
    }

    // MARK: - Credential

    @Sendable
    func current(_: Request, ctx: AppRequestContext) async throws -> HermesMirrorWebhookDTO {
        let tenantID = try ctx.requireTenantID()
        guard let row = try await HermesMirrorWebhook.query(on: fluent.db(), tenantID: tenantID).first() else {
            throw HTTPError(.notFound, message: "hermes_webhook_not_configured")
        }
        return Self.dto(row)
    }

    /// Mints a new token + secret. The secret is in the response and nowhere
    /// else a client can reach: it is sealed at rest and never logged.
    ///
    /// Gated on the tenant's Hermes reporting `admin_config_rw` — without it
    /// the user cannot store the URL and secret on their Hermes, so handing
    /// them a credential would only be a dead end. Managed tenants always
    /// qualify; a BYO Hermes that says nothing degrades to
    /// `hermes_admin_config_rw_required` and keeps polling.
    @Sendable
    func rotate(_: Request, ctx: AppRequestContext) async throws -> HermesMirrorWebhookDTO {
        let tenantID = try ctx.requireTenantID()
        guard await service.supportsAdminConfig(tenantID: tenantID) else {
            throw HTTPError(.conflict, message: "hermes_admin_config_rw_required")
        }
        let secret = Self.randomSecret()
        let sealed = try secretBox.seal(secret, tenantID: tenantID)
        let row = try await HermesMirrorWebhook.query(on: fluent.db(), tenantID: tenantID).first() ?? HermesMirrorWebhook()
        if row.id == nil {
            row.id = UUID()
            row.tenantID = tenantID
        }
        row.token = Self.randomToken()
        row.secretCiphertext = sealed.ciphertext
        row.secretNonce = sealed.nonce
        row.rotatedAt = clock()
        try await row.save(on: fluent.db())
        logger.info("hermes mirror webhook rotated", metadata: ["tenant": .string(tenantID.uuidString)])
        return Self.dto(row, secret: secret)
    }

    static func dto(_ row: HermesMirrorWebhook, secret: String? = nil) -> HermesMirrorWebhookDTO {
        HermesMirrorWebhookDTO(
            path: "\(routePrefix)/\(row.token)",
            token: row.token,
            secret: secret,
            signatureHeader: signatureHeader,
            timestampHeader: timestampHeader,
            replayWindowSeconds: Int(replayWindow),
            rotatedAt: row.rotatedAt
        )
    }

    // MARK: - Push

    @Sendable
    func ingest(_ request: Request, ctx: AppRequestContext) async throws -> HermesJobCollectResultDTO {
        let (tenantID, payload) = try await authenticate(request, ctx: ctx)
        let jobID = try await HermesMirrorController.mapErrors { try HermesJobID.validate(payload.jobID) }
        do {
            return try await service.collectJobRuns(tenantID: tenantID, jobID: jobID)
        } catch {
            // The poller runs the same pass; a push that could not collect
            // (Hermes busy, another mirror operation in flight, the job not
            // mirrored yet) costs latency, never correctness.
            logger.debug("hermes mirror webhook collect deferred to the poller", metadata: [
                "tenant": .string(tenantID.uuidString), "job": .string(jobID),
                "error": "\(HermesMirrorService.describe(error))",
            ])
            return HermesJobCollectResultDTO(
                hermesJobID: jobID, fetched: 0, inserted: 0, skipped: 0, filesWritten: 0, truncated: false
            )
        }
    }

    /// Token → tenant, then timestamp freshness, then a constant-time HMAC
    /// check over `<timestamp>.<body>`. Every failure is the same 401.
    private func authenticate(_ request: Request, ctx: AppRequestContext) async throws -> (UUID, HermesJobWebhookPayload) {
        let unauthorized = HTTPError(.unauthorized, message: "hermes_webhook_unauthorized")
        guard let token = ctx.parameters.get("token"), !token.isEmpty, token.count <= 128,
              let row = try await webhook(token: String(token))
        else { throw unauthorized }
        guard let rawTimestamp = Self.header(request, Self.timestampHeader),
              let timestamp = TimeInterval(rawTimestamp),
              abs(clock().timeIntervalSince1970 - timestamp) <= Self.replayWindow,
              let signature = Self.header(request, Self.signatureHeader)
        else { throw unauthorized }
        let buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        let body = Data(buffer.readableBytesView)
        guard let secret = try? secretBox.open(.init(ciphertext: row.secretCiphertext, nonce: row.secretNonce), tenantID: row.tenantID),
              WorkflowWebhookSignature.verify(signature, secret: secret, timestamp: rawTimestamp, body: body)
        else { throw unauthorized }
        guard let payload = try? JSONDecoder().decode(HermesJobWebhookPayload.self, from: body) else {
            throw HTTPError(.badRequest, message: "hermes_webhook_invalid_payload")
        }
        return (row.tenantID, payload)
    }

    /// The token is the routing key and is unique across tenants, so this is
    /// the one lookup that is deliberately not tenant-scoped.
    private func webhook(token: String) async throws -> HermesMirrorWebhook? {
        // Fluent query builder, not a collection.
        // swiftlint:disable:next first_where
        try await HermesMirrorWebhook.query(on: fluent.db()).filter(\.$token == token).first()
    }

    /// `HTTPField.Name` is failable; an unparseable constant here would be a
    /// programmer error, and treating it as a missing header just fails the
    /// request closed.
    static func header(_ request: Request, _ name: String) -> String? {
        guard let field = HTTPField.Name(name) else { return nil }
        return request.headers[field]
    }

    /// 32 bytes, hex — URL-safe without escaping, and the only thing in the
    /// path, so it carries all the unguessability.
    private static func randomToken() -> String {
        randomBytes(32).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSecret() -> String {
        Data(randomBytes(32)).base64EncodedString()
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

extension HermesMirrorService {
    /// True when the tenant's Hermes reports `admin_config_rw` — the
    /// precondition for the inbound webhook, because the user has to be able
    /// to store the URL and secret on their own Hermes for it to ever fire.
    /// Any failure reading that is a "no": the webhook is an optimisation and
    /// declining to offer one never breaks collection.
    func supportsAdminConfig(tenantID: UUID) async -> Bool {
        guard let transport = try? await transports.transport(tenantID: tenantID),
              let status = try? await transport.status()
        else { return false }
        return status.adminConfigRW == true
    }
}
