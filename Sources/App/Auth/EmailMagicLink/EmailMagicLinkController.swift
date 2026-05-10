import Foundation
import Hummingbird
import Logging

struct EmailMagicStartRequest: Codable, Sendable {
    let email: String
}

struct EmailMagicStartResponse: Codable, ResponseEncodable, Sendable {
    let challengeId: UUID
    let expiresAt: Date
}

struct EmailMagicVerifyRequest: Codable, Sendable {
    let email: String
    let code: String
}

extension AuthError {
    static let invalidEmail = HTTPError(.badRequest, message: "email looks invalid")
}

/// Passwordless email signin via OTP. Parallel to the existing
/// email+password flow — does NOT replace it. Net-new users get an auto
/// generated username; emailVerified is set true once the OTP succeeds.
struct EmailMagicLinkController {
    let authService: any AuthService
    let emailSender: any EmailOTPSender
    let generator: any OTPCodeGenerator
    let challengeStore: PreAuthChallengeStore
    let logger: Logger

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("/email/start", use: start)
        group.post("/email/verify", use: verify)
    }

    @Sendable
    func start(_ req: Request, ctx: AppRequestContext) async throws -> EmailMagicStartResponse {
        let body = try await req.decode(as: EmailMagicStartRequest.self, context: ctx)
        let email = try Self.normalizeEmail(body.email)
        let code = generator.generate()
        let (id, expiresAt) = await challengeStore.issue(
            channel: "email",
            destination: email,
            purpose: "magic_link",
            code: code
        )
        try await emailSender.send(code: code, to: email, purpose: "magic_link")
        logger.info("magic-link OTP issued: email=\(email)")
        return EmailMagicStartResponse(challengeId: id, expiresAt: expiresAt)
    }

    @Sendable
    func verify(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: EmailMagicVerifyRequest.self, context: ctx)
        let email = try Self.normalizeEmail(body.email)
        guard await challengeStore.consume(destination: email, code: body.code) != nil else {
            throw AuthError.otpInvalid
        }
        let user = try await authService.upsertOAuthUser(
            provider: "email_magic_link",
            providerUserID: email,
            email: email,
            emailVerified: true
        )
        return try await authService.issueTokens(for: user)
    }

    private static func normalizeEmail(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.contains("@"), s.count >= 5, s.count <= 254 else {
            throw AuthError.invalidEmail
        }
        return s
    }
}
