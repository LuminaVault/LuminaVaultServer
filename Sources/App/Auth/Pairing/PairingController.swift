import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

/// HER — QR-from-mobile web sign-in.
///
/// Lets an already-authenticated iOS app approve a browser session:
///   1. Browser calls `POST /v1/auth/pairing/start` → `{ pairingId, code, expiresAt }`
///      and renders `pairingId`/`code` as a QR.
///   2. The app scans, confirms `code`, and calls
///      `POST /v1/auth/pairing/{pairingId}/approve` (JWT-authenticated).
///   3. Browser polls `GET /v1/auth/pairing/{pairingId}` until it gets the
///      minted token pair.
///
/// `pairingId` is an unguessable UUID and is the bearer secret for polling.
/// Records live in a `PersistDriver` with a short TTL. Single-process
/// `MemoryPersistDriver` is fine for MVP; a multi-replica deployment must use
/// a shared (Redis) driver so any replica can resolve a pairing.
struct PairingController {
    let service: any AuthService
    let storage: any PersistDriver
    let rateLimitStorage: any PersistDriver
    let telemetry: RouteTelemetry
    let generator: any OTPCodeGenerator
    let logger: Logger

    /// Time a pending pairing stays scannable, and how long an approved record
    /// lingers for the browser to pick up.
    private let ttl: Duration = .seconds(120)

    private func key(_ pairingID: String) -> String { "pairing:\(pairingID)" }

    private func rl(_ policy: RateLimitPolicy) -> RateLimitMiddleware {
        RateLimitMiddleware(policy: policy, storage: rateLimitStorage)
    }

    func addRoutes(to router: Router<AppRequestContext>, authenticator: JWTAuthenticator) {
        // Per the RouterGroup mutation note in AuthController: one fresh group
        // per middleware stack so limiters/authenticators don't leak.
        router.group("/v1/auth/pairing").add(middleware: rl(.registerByIP)).post("/start", use: start)
        router.group("/v1/auth/pairing").get("/:pairingId", use: poll)
        router.group("/v1/auth/pairing").add(middleware: authenticator).post("/:pairingId/approve", use: approve)
    }

    // MARK: - Handlers

    /// Unauthenticated. Mint a pending pairing and return the QR payload parts.
    @Sendable
    func start(_: Request, ctx _: AppRequestContext) async throws -> PairingStartResponse {
        let pairingID = UUID().uuidString
        let code = generator.generate()
        let expiresAtMs = Int(Date().addingTimeInterval(ttl.seconds).timeIntervalSince1970 * 1000)
        let record = PairingRecord(code: code, expiresAtMs: expiresAtMs, approved: false, auth: nil)
        try await telemetry.observe("auth.pairing.start") {
            try await storage.set(key: key(pairingID), value: record, expires: ttl)
        }
        return PairingStartResponse(pairingId: pairingID, code: code, expiresAt: expiresAtMs)
    }

    /// Unauthenticated (pairingId is the secret). Pending → `{ approved: false }`;
    /// approved → the minted token pair; unknown/expired → 404.
    @Sendable
    func poll(_: Request, ctx: AppRequestContext) async throws -> PairingPollResponse {
        guard let pairingID = ctx.parameters.get("pairingId") else {
            throw HTTPError(.badRequest, message: "missing pairingId")
        }
        guard let record = try await storage.get(key: key(pairingID), as: PairingRecord.self) else {
            throw HTTPError(.notFound, message: "pairing expired or unknown")
        }
        guard record.approved, let auth = record.auth else {
            return PairingPollResponse(approved: false)
        }
        return PairingPollResponse(
            approved: true,
            userId: auth.userId,
            email: auth.email,
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken,
            expiresIn: auth.expiresIn,
            vaultInitialized: auth.vaultInitialized,
        )
    }

    /// JWT-authenticated. The app confirms `code` and approves; we mint tokens
    /// for the authenticated user and stash them on the pairing for the poller.
    @Sendable
    func approve(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        guard let pairingID = ctx.parameters.get("pairingId") else {
            throw HTTPError(.badRequest, message: "missing pairingId")
        }
        let body = try await req.decode(as: PairingApproveRequest.self, context: ctx)
        guard var record = try await storage.get(key: key(pairingID), as: PairingRecord.self) else {
            throw HTTPError(.notFound, message: "pairing expired or unknown")
        }
        guard !record.approved else {
            throw HTTPError(.conflict, message: "pairing already approved")
        }
        guard record.code == body.code else {
            throw HTTPError(.unauthorized, message: "pairing code mismatch")
        }
        let auth = try await telemetry.observe("auth.pairing.approve") {
            try await service.issueTokens(for: user)
        }
        record.approved = true
        record.auth = PairingRecord.Auth(
            userId: auth.userId,
            email: auth.email,
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken,
            expiresIn: auth.expiresIn,
            vaultInitialized: auth.vaultInitialized,
        )
        try await storage.set(key: key(pairingID), value: record, expires: ttl)
        return Response(status: .noContent)
    }
}

// MARK: - DTOs

struct PairingStartResponse: ResponseEncodable, Codable {
    let pairingId: String
    let code: String
    /// Epoch milliseconds — the web client renders a countdown.
    let expiresAt: Int
}

struct PairingApproveRequest: Codable {
    let code: String
}

struct PairingPollResponse: ResponseEncodable, Codable {
    let approved: Bool
    var userId: UUID?
    var email: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresIn: Int?
    var vaultInitialized: Bool?

    init(
        approved: Bool,
        userId: UUID? = nil,
        email: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresIn: Int? = nil,
        vaultInitialized: Bool? = nil,
    ) {
        self.approved = approved
        self.userId = userId
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.vaultInitialized = vaultInitialized
    }
}

/// Persisted pairing state (short TTL). `auth` is populated on approval so the
/// browser poll can retrieve the minted token pair exactly once before expiry.
struct PairingRecord: Codable {
    let code: String
    let expiresAtMs: Int
    var approved: Bool
    var auth: Auth?

    struct Auth: Codable {
        let userId: UUID
        let email: String?
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let vaultInitialized: Bool
    }
}

private extension Duration {
    /// Whole seconds component, for epoch math.
    var seconds: TimeInterval { TimeInterval(components.seconds) }
}
