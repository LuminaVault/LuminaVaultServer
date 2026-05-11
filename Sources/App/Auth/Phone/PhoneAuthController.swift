import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

// MARK: - DTOs

struct PhoneStartRequest: Codable, Sendable {
    let phone: String
}

struct PhoneStartResponse: Codable, ResponseEncodable, Sendable {
    let challengeId: UUID
    let expiresAt: Date
}

struct PhoneVerifyRequest: Codable, Sendable {
    let phone: String
    let code: String
}

// MARK: - Pre-auth challenge store

/// Outcome of `PreAuthChallengeStore.consumeTyped` so the caller can
/// distinguish a code that was wrong (`.wrongCode`/`.lockedOut` → 401)
/// from a challenge whose lifetime ran out (`.expired` → 410 Gone).
/// HER-137 requires the 410 distinction so the iOS client knows to
/// re-issue rather than re-prompt.
enum ConsumeOutcome: Sendable {
    case ok(destination: String, purpose: String)
    case notFound
    case expired
    case lockedOut
    case wrongCode
}

/// Single-instance in-memory store for OTP challenges issued BEFORE a User
/// row exists. Multi-replica deployments must move this onto a shared
/// `PersistDriver` (Redis). Fine for the current single-VPS MVP.
actor PreAuthChallengeStore {
    private struct Entry {
        let id: UUID
        let codeHash: String
        var attempts: Int
        let channel: String         // "sms" | "email"
        let destination: String     // phone (E.164) or email
        let purpose: String
        let expiresAt: Date
    }

    private var byID: [UUID: Entry] = [:]
    private var latestByDestination: [String: UUID] = [:]   // dedup-by-recipient

    private let lifetime: TimeInterval
    private let maxAttempts: Int

    /// `lifetime` is overridable so unit tests can drive the `.expired` path
    /// without sleeping for 5 minutes. Negative values yield an already-expired
    /// challenge on first call to `consumeTyped`.
    init(lifetime: TimeInterval = 60 * 5, maxAttempts: Int = 5) {
        self.lifetime = lifetime
        self.maxAttempts = maxAttempts
    }

    func issue(channel: String, destination: String, purpose: String, code: String) -> (id: UUID, expiresAt: Date) {
        // Burn any prior outstanding challenge for the same destination so
        // the latest send wins (and old codes can't be reused after resend).
        if let oldID = latestByDestination[destination] { byID[oldID] = nil }

        let id = UUID()
        let expiresAt = Date().addingTimeInterval(lifetime)
        let entry = Entry(
            id: id,
            codeHash: Self.sha256(code),
            attempts: 0,
            channel: channel,
            destination: destination,
            purpose: purpose,
            expiresAt: expiresAt
        )
        byID[id] = entry
        latestByDestination[destination] = id
        return (id, expiresAt)
    }

    /// Returns the destination + purpose if the code matches an active
    /// challenge. Atomic on the entry: increments attempts + burns on max.
    /// Legacy optional-returning API retained for `EmailMagicLinkController`
    /// which doesn't need the 410-vs-401 distinction yet.
    func consume(destination: String, code: String) -> (destination: String, purpose: String)? {
        if case let .ok(dest, purpose) = consumeTyped(destination: destination, code: code) {
            return (dest, purpose)
        }
        return nil
    }

    /// Typed variant used by `PhoneAuthController` so it can return
    /// 410 Gone for `.expired` and 401 for any other failure.
    func consumeTyped(destination: String, code: String) -> ConsumeOutcome {
        guard let id = latestByDestination[destination], var entry = byID[id] else {
            return .notFound
        }
        if entry.expiresAt < Date() {
            byID[id] = nil
            latestByDestination[destination] = nil
            return .expired
        }
        if entry.attempts >= maxAttempts {
            byID[id] = nil
            latestByDestination[destination] = nil
            return .lockedOut
        }
        guard entry.codeHash == Self.sha256(code) else {
            entry.attempts += 1
            byID[id] = entry
            if entry.attempts >= maxAttempts {
                byID[id] = nil
                latestByDestination[destination] = nil
                return .lockedOut
            }
            return .wrongCode
        }
        // Burn-on-success.
        byID[id] = nil
        latestByDestination[destination] = nil
        return .ok(destination: entry.destination, purpose: entry.purpose)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

extension AuthError {
    static let invalidPhone = HTTPError(.badRequest, message: "phone must be E.164 (^\\+[1-9]\\d{6,14}$)")
    static let otpInvalid  = HTTPError(.unauthorized, message: "invalid or expired code")
    static let otpExpired  = HTTPError(.gone, message: "challenge expired; request a new code")
}

// MARK: - Controller

/// Phone signup/login via SMS OTP. Reuses `AuthService.upsertOAuthUser`
/// with `provider="phone"`, `providerUserID=<E.164>`. Net-new users get
/// a placeholder email + auto-generated username.
///
/// Routing:
///   * `POST /v1/auth/phone/start`  — stacked rate-limit (3/min + 10/day per IP)
///   * `POST /v1/auth/phone/verify` — unlimited (controller-burns on bad code)
struct PhoneAuthController {
    let authService: any AuthService
    let smsSender: any SMSSender
    let generator: any OTPCodeGenerator
    let challengeStore: PreAuthChallengeStore
    let rateLimitStorage: any PersistDriver
    let logger: Logger

    /// Attaches `/phone/start` and `/phone/verify` to `router` under `basePath`.
    /// Uses fresh `router.group(basePath)` per route so the stacked rate-limit
    /// middlewares on `/phone/start` do not leak onto `/phone/verify` —
    /// `RouterGroup.add(middleware:)` mutates and the leak is silent.
    func addRoutes(to router: Router<AppRequestContext>, basePath: RouterPath = "/v1/auth") {
        router.group(basePath)
            .add(middleware: RateLimitMiddleware(policy: .phoneStartByIPPerMinute, storage: rateLimitStorage))
            .add(middleware: RateLimitMiddleware(policy: .phoneStartByIPDaily, storage: rateLimitStorage))
            .post("/phone/start", use: start)
        router.group(basePath).post("/phone/verify", use: verify)
    }

    @Sendable
    func start(_ req: Request, ctx: AppRequestContext) async throws -> PhoneStartResponse {
        let body = try await req.decode(as: PhoneStartRequest.self, context: ctx)
        let phone = try Self.validateE164(body.phone)
        let code = generator.generate()
        let (id, expiresAt) = await challengeStore.issue(
            channel: "sms",
            destination: phone,
            purpose: "phone_signin",
            code: code
        )
        try await smsSender.send(code: code, to: phone, purpose: "phone_signin")
        logger.info("phone OTP issued: phone=\(phone)")
        return PhoneStartResponse(challengeId: id, expiresAt: expiresAt)
    }

    @Sendable
    func verify(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: PhoneVerifyRequest.self, context: ctx)
        let phone = try Self.validateE164(body.phone)
        switch await challengeStore.consumeTyped(destination: phone, code: body.code) {
        case .ok:
            break
        case .expired:
            throw AuthError.otpExpired
        case .notFound, .wrongCode, .lockedOut:
            throw AuthError.otpInvalid
        }
        let placeholderEmail = "\(phone.dropFirst())@phone.luminavault.local"
        let user = try await authService.upsertOAuthUser(
            provider: "phone",
            providerUserID: phone,
            email: placeholderEmail,
            emailVerified: false
        )
        return try await authService.issueTokens(for: user)
    }

    private static let e164Pattern = #"^\+[1-9]\d{6,14}$"#

    static func validateE164(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: e164Pattern, options: .regularExpression) != nil else {
            throw AuthError.invalidPhone
        }
        return trimmed
    }
}
