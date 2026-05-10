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

    private let lifetime: TimeInterval = 60 * 5
    private let maxAttempts: Int = 5

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
    func consume(destination: String, code: String) -> (destination: String, purpose: String)? {
        guard let id = latestByDestination[destination], var entry = byID[id] else {
            return nil
        }
        if entry.expiresAt < Date() {
            byID[id] = nil
            return nil
        }
        if entry.attempts >= maxAttempts {
            byID[id] = nil
            return nil
        }
        guard entry.codeHash == Self.sha256(code) else {
            entry.attempts += 1
            byID[id] = entry
            if entry.attempts >= maxAttempts {
                byID[id] = nil
                latestByDestination[destination] = nil
            }
            return nil
        }
        // Burn-on-success.
        byID[id] = nil
        latestByDestination[destination] = nil
        return (entry.destination, entry.purpose)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

extension AuthError {
    static let invalidPhone = HTTPError(.badRequest, message: "phone must be E.164 (^\\+[1-9]\\d{6,14}$)")
    static let otpInvalid  = HTTPError(.unauthorized, message: "invalid or expired code")
}

// MARK: - Controller

/// Phone signup/login via SMS OTP. Reuses `AuthService.upsertOAuthUser`
/// with `provider="phone"`, `providerUserID=<E.164>`. Net-new users get
/// a placeholder email + auto-generated username.
struct PhoneAuthController {
    let authService: any AuthService
    let smsSender: any SMSSender
    let generator: any OTPCodeGenerator
    let challengeStore: PreAuthChallengeStore
    let logger: Logger

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("/phone/start", use: start)
        group.post("/phone/verify", use: verify)
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
        guard let _ = await challengeStore.consume(destination: phone, code: body.code) else {
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
