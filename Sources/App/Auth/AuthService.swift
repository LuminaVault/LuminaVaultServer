import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import JWTKit

protocol AuthService: Sendable {
    func register(email: String, username: String, password: String) async throws -> AuthResponse
    /// `requireMFA=true` when the client advertises `mfa-auth-v1` capability —
    /// triggers an email-OTP challenge instead of immediately issuing tokens.
    func login(email: String, password: String, requireMFA: Bool) async throws -> AuthResponse
    func refresh(refreshToken: String) async throws -> AuthResponse
    func revokeRefresh(refreshToken: String) async throws
    func issueTokens(for user: User) async throws -> AuthResponse
    /// Verify an OTP code; on success issues tokens, on failure throws.
    func verifyMFA(challengeID: UUID, code: String) async throws -> AuthResponse
    /// Re-issue an OTP for an active challenge owned by the given email.
    func resendMFA(email: String) async throws
    /// Exchange a provider-issued id_token for app tokens.
    /// Creates or links the OAuthIdentity to a User as needed.
    func exchangeOAuth(provider: any OAuthProvider, idToken: String) async throws -> AuthResponse
    /// Shared upsert path for any provider (Apple, Google, X, Phone, Email magic-link).
    /// Caller decides how to verify the provider-side credential before calling.
    func upsertOAuthUser(provider: String, providerUserID: String, email: String, emailVerified: Bool) async throws -> User
    /// Email-OTP password reset flow.
    func forgotPassword(email: String) async throws
    func resendReset(email: String) async throws
    func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthResponse
    /// Email verification (HER-87): issue OTP that flips `users.is_verified` on confirm.
    /// `sendVerification` is silent on unknown email (no enumeration leak).
    func sendVerification(email: String) async throws
    func confirmEmail(email: String, code: String) async throws
}

struct DefaultAuthService: AuthService {
    let repo: any AuthRepository
    let hasher: any PasswordHasher
    let fluent: Fluent
    let jwtKeys: JWTKeyCollection
    let jwtKID: JWKIdentifier
    let mfaService: any MFAService
    let resetCodeSender: any EmailOTPSender
    let resetCodeGenerator: any OTPCodeGenerator
    let verificationCodeSender: any EmailOTPSender
    let verificationCodeGenerator: any OTPCodeGenerator
    let hermesProfileService: HermesProfileService
    let soulService: SOULService

    let accessTokenLifetime: TimeInterval = 60 * 60                  // 1 hour
    let refreshTokenLifetime: TimeInterval = 60 * 60 * 24 * 30       // 30 days
    let maxFailedLogins: Int = 5
    let lockoutDuration: TimeInterval = 60 * 15                      // 15 min
    let minPasswordLength: Int = 12
    let resetCodeLifetime: TimeInterval = 60 * 15                    // 15 min
    let maxResetFailures: Int = 5
    let resetLockoutDuration: TimeInterval = 60 * 30                 // 30 min
    let verifyCodeLifetime: TimeInterval = 60 * 60 * 24              // 24 hours
    let maxVerifyFailures: Int = 5
    let verifyLockoutDuration: TimeInterval = 60 * 30                // 30 min

    func register(email: String, username rawUsername: String, password: String) async throws -> AuthResponse {
        guard password.count >= minPasswordLength else { throw AuthError.weakPassword }
        let username = try UsernamePolicy.validate(rawUsername)
        if try await repo.findUser(byEmail: email) != nil { throw AuthError.emailExists }
        if try await repo.findUser(byUsername: username) != nil { throw AuthError.usernameTaken }
        let hash = await hasher.hash(password)
        let user = try await repo.createUser(email: email, username: username, passwordHash: hash)
        try await Self.applyTrialDefaults(to: user, on: fluent.db())
        do {
            try await hermesProfileService.ensure(for: user)
        } catch {
            try? await user.delete(force: true, on: fluent.db())
            throw HTTPError(.serviceUnavailable, message: "could not provision hermes profile")
        }
        do {
            try soulService.initIfMissing(for: user)
        } catch {
            // SOUL.md is load-bearing for Hermes voice; the user should not
            // exist without it. Roll back so a retry produces a clean state.
            try? await user.delete(force: true, on: fluent.db())
            throw HTTPError(.serviceUnavailable, message: "could not initialize SOUL.md")
        }
        return try await issueTokens(for: user)
    }

    /// Stamps a freshly created user with the 14-day trial window.
    /// Idempotent: a re-entrant call won't extend an existing trial.
    static func applyTrialDefaults(
        to user: User,
        on db: any Database,
        trialDays: Int = 14,
        now: Date = Date()
    ) async throws {
        user.tier = "trial"
        if user.tierExpiresAt == nil {
            user.tierExpiresAt = now.addingTimeInterval(TimeInterval(trialDays) * 86_400)
        }
        try await user.save(on: db)
    }

    func login(email: String, password: String, requireMFA: Bool) async throws -> AuthResponse {
        guard let user = try await repo.findUser(byEmail: email) else {
            throw AuthError.invalidCredentials
        }
        if let lock = user.lockoutUntil, lock > Date() { throw AuthError.accountLocked }

        let userID = try user.requireID()
        guard await hasher.verify(password, hash: user.passwordHash) else {
            let nextAttempts = user.failedLoginAttempts + 1
            let lockoutAt: Date? = nextAttempts >= maxFailedLogins
                ? Date().addingTimeInterval(lockoutDuration) : nil
            try await repo.incrementFailedLogin(userID: userID, lockoutAt: lockoutAt)
            throw AuthError.invalidCredentials
        }
        try await repo.resetFailedLogin(userID: userID)

        if requireMFA {
            let challengeID = try await mfaService.issue(forUser: user, purpose: "login")
            return try mfaPendingResponse(for: user, challengeID: challengeID)
        }
        return try await issueTokens(for: user)
    }

    func verifyMFA(challengeID: UUID, code: String) async throws -> AuthResponse {
        guard try await mfaService.verify(challengeID: challengeID, code: code) else {
            throw AuthError.mfaInvalid
        }
        // Look up the challenge to find the owning user.
        guard let row = try await MFAChallenge.find(challengeID, on: fluent.db()),
              let user = try await repo.findUser(byID: row.tenantID)
        else { throw AuthError.mfaInvalid }
        return try await issueTokens(for: user)
    }

    func resendMFA(email: String) async throws {
        guard let user = try await repo.findUser(byEmail: email) else {
            throw AuthError.invalidCredentials
        }
        _ = try await mfaService.issue(forUser: user, purpose: "login")
    }

    func forgotPassword(email: String) async throws {
        guard let user = try await repo.findUser(byEmail: email) else { return }   // no-op (don't leak existence)
        try await issueResetCode(for: user)
    }

    func resendReset(email: String) async throws {
        guard let user = try await repo.findUser(byEmail: email) else { return }
        try await issueResetCode(for: user)
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthResponse {
        guard newPassword.count >= minPasswordLength else { throw AuthError.weakPassword }
        guard let user = try await repo.findUser(byEmail: email) else {
            throw AuthError.resetCodeInvalid
        }
        let userID = try user.requireID()

        // Find latest unused, non-expired token for this tenant.
        guard let row = try await PasswordResetToken.query(on: fluent.db(), tenantID: userID)
            .filter(\.$usedAt == nil)
            .sort(\.$createdAt, .descending)
            .first()
        else { throw AuthError.resetCodeInvalid }

        if let lock = row.lockedUntil, lock > Date() { throw AuthError.resetLocked }
        if row.expiresAt < Date() { throw AuthError.resetCodeInvalid }

        if row.codeHash == sha256Hex(code) {
            row.usedAt = Date()
            try await row.save(on: fluent.db())
            user.passwordHash = await hasher.hash(newPassword)
            user.failedLoginAttempts = 0
            user.lockoutUntil = nil
            try await user.save(on: fluent.db())

            // Revoke all active refresh tokens — force re-login on every device.
            try await RefreshToken.query(on: fluent.db(), tenantID: userID)
                .filter(\.$revokedAt == nil)
                .set(\.$revokedAt, to: Date())
                .update()

            return try await issueTokens(for: user)
        } else {
            row.failedAttempts += 1
            if row.failedAttempts >= maxResetFailures {
                row.lockedUntil = Date().addingTimeInterval(resetLockoutDuration)
            }
            try await row.save(on: fluent.db())
            throw AuthError.resetCodeInvalid
        }
    }

    func sendVerification(email: String) async throws {
        guard let user = try await repo.findUser(byEmail: email) else { return }   // no-op (don't leak existence)
        if user.isVerified { return }                                              // idempotent: nothing to do
        try await issueVerificationCode(for: user)
    }

    func confirmEmail(email: String, code: String) async throws {
        guard let user = try await repo.findUser(byEmail: email) else {
            throw AuthError.verifyCodeInvalid
        }
        let userID = try user.requireID()
        if user.isVerified { return }                                              // idempotent

        guard let row = try await EmailVerificationToken.query(on: fluent.db(), tenantID: userID)
            .filter(\.$usedAt == nil)
            .sort(\.$createdAt, .descending)
            .first()
        else { throw AuthError.verifyCodeInvalid }

        if let lock = row.lockedUntil, lock > Date() { throw AuthError.verifyLocked }
        if row.expiresAt < Date() { throw AuthError.verifyCodeInvalid }

        if row.codeHash == sha256Hex(code) {
            row.usedAt = Date()
            try await row.save(on: fluent.db())
            user.isVerified = true
            try await user.save(on: fluent.db())
        } else {
            row.failedAttempts += 1
            if row.failedAttempts >= maxVerifyFailures {
                row.lockedUntil = Date().addingTimeInterval(verifyLockoutDuration)
            }
            try await row.save(on: fluent.db())
            throw AuthError.verifyCodeInvalid
        }
    }

    private func issueVerificationCode(for user: User) async throws {
        let userID = try user.requireID()
        let code = verificationCodeGenerator.generate()
        let row = EmailVerificationToken(
            tenantID: userID,
            codeHash: sha256Hex(code),
            expiresAt: Date().addingTimeInterval(verifyCodeLifetime)
        )
        try await row.save(on: fluent.db())
        try await verificationCodeSender.send(code: code, to: user.email, purpose: "verify")
    }

    private func issueResetCode(for user: User) async throws {
        let userID = try user.requireID()
        let code = resetCodeGenerator.generate()
        let row = PasswordResetToken(
            tenantID: userID,
            codeHash: sha256Hex(code),
            expiresAt: Date().addingTimeInterval(resetCodeLifetime)
        )
        try await row.save(on: fluent.db())
        try await resetCodeSender.send(code: code, to: user.email, purpose: "reset")
    }

    func exchangeOAuth(provider: any OAuthProvider, idToken: String) async throws -> AuthResponse {
        let info = try await provider.verify(idToken: idToken)
        let user = try await upsertOAuthUser(
            provider: provider.name,
            providerUserID: info.providerUserID,
            email: info.email,
            emailVerified: info.emailVerified
        )
        return try await issueTokens(for: user)
    }

    /// Shared upsert path used by every passwordless / OAuth signin.
    /// Lookup precedence:
    ///  1. Match (provider, providerUserID) → existing User
    ///  2. Match by email → link new identity to existing User
    ///  3. Create User + identity
    /// Caller invokes `issueTokens(for: user)` separately to attach JWT.
    func upsertOAuthUser(
        provider: String,
        providerUserID: String,
        email: String,
        emailVerified: Bool
    ) async throws -> User {
        // 1) Existing identity for this (provider, providerUserID) → login.
        if let identity = try await OAuthIdentity.query(on: fluent.db())
            .filter(\.$provider == provider)
            .filter(\.$providerUserID == providerUserID)
            .first(),
           let user = try await repo.findUser(byID: identity.tenantID)
        {
            return user
        }

        // 2) User exists with this email → link new identity.
        if let user = try await repo.findUser(byEmail: email) {
            let identity = OAuthIdentity(
                tenantID: try user.requireID(),
                provider: provider,
                providerUserID: providerUserID,
                email: email,
                emailVerified: emailVerified
            )
            try await identity.save(on: fluent.db())
            return user
        }

        // 3) Net new user. No password (set random hash; OAuth-only).
        let randomHash = await hasher.hash(UUID().uuidString + UUID().uuidString)
        let username = try await uniquePlaceholderUsername()
        let user = try await repo.createUser(email: email, username: username, passwordHash: randomHash)
        try await Self.applyTrialDefaults(to: user, on: fluent.db())
        let identity = OAuthIdentity(
            tenantID: try user.requireID(),
            provider: provider,
            providerUserID: providerUserID,
            email: email,
            emailVerified: emailVerified
        )
        try await identity.save(on: fluent.db())
        do {
            try await hermesProfileService.ensure(for: user)
        } catch {
            try? await user.delete(force: true, on: fluent.db())
            throw HTTPError(.serviceUnavailable, message: "could not provision hermes profile")
        }
        do {
            try soulService.initIfMissing(for: user)
        } catch {
            try? await user.delete(force: true, on: fluent.db())
            throw HTTPError(.serviceUnavailable, message: "could not initialize SOUL.md")
        }
        return user
    }

    /// Generates a placeholder username (`oauth-<8hex>`) and retries on the
    /// vanishingly rare uniqueness collision. After 5 failures we give up
    /// rather than spin forever.
    private func uniquePlaceholderUsername(maxAttempts: Int = 5) async throws -> String {
        for _ in 0..<maxAttempts {
            let candidate = UsernamePolicy.placeholder()
            if try await repo.findUser(byUsername: candidate) == nil {
                return candidate
            }
        }
        throw HTTPError(.internalServerError, message: "could not allocate placeholder username")
    }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        let hash = sha256Hex(refreshToken)
        let row = try await RefreshToken.query(on: fluent.db())
            .filter(\.$tokenHash == hash)
            .filter(\.$revokedAt == nil)
            .first()
        guard let row, row.expiresAt > Date(),
              let user = try await repo.findUser(byID: row.tenantID)
        else { throw AuthError.invalidRefresh }

        row.revokedAt = Date()
        try await row.save(on: fluent.db())
        return try await issueTokens(for: user)
    }

    func revokeRefresh(refreshToken: String) async throws {
        let hash = sha256Hex(refreshToken)
        if let row = try await RefreshToken.query(on: fluent.db())
            .filter(\.$tokenHash == hash)
            .first()
        {
            row.revokedAt = Date()
            try await row.save(on: fluent.db())
        }
    }

    func issueTokens(for user: User) async throws -> AuthResponse {
        let userID = try user.requireID()
        let hpid = try await hermesProfileService.find(for: user)?.hermesProfileID
        let now = Date()
        let access = SessionToken(
            userID: userID,
            expiration: now.addingTimeInterval(accessTokenLifetime),
            issuedAt: now,
            hpid: hpid
        )
        let signed = try await jwtKeys.sign(access, kid: jwtKID)
        let refreshRaw = randomToken()
        let refreshRow = RefreshToken(
            tenantID: userID,
            tokenHash: sha256Hex(refreshRaw),
            expiresAt: Date().addingTimeInterval(refreshTokenLifetime)
        )
        try await refreshRow.save(on: fluent.db())
        return AuthResponse(
            userId: userID,
            email: user.email,
            accessToken: signed,
            refreshToken: refreshRaw,
            expiresIn: Int(accessTokenLifetime),
            mfaRequired: nil,
            mfaChallengeId: nil
        )
    }

    /// Issues an "MFA pending" placeholder response: no tokens, just the challengeId.
    /// Call after creating an MFAChallenge.
    func mfaPendingResponse(for user: User, challengeID: UUID) throws -> AuthResponse {
        AuthResponse(
            userId: try user.requireID(),
            email: user.email,
            accessToken: "",
            refreshToken: "",
            expiresIn: 0,
            mfaRequired: true,
            mfaChallengeId: challengeID
        )
    }

    // MARK: - helpers

    private func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64URLEncodedString()
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
