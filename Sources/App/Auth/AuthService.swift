import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import JWTKit

protocol AuthService: Sendable {
    func register(email: String, password: String) async throws -> AuthResponse
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
}

struct DefaultAuthService: AuthService {
    let repo: any AuthRepository
    let hasher: any PasswordHasher
    let fluent: Fluent
    let jwtKeys: JWTKeyCollection
    let jwtKID: JWKIdentifier
    let mfaService: any MFAService

    let accessTokenLifetime: TimeInterval = 60 * 60                  // 1 hour
    let refreshTokenLifetime: TimeInterval = 60 * 60 * 24 * 30       // 30 days
    let maxFailedLogins: Int = 5
    let lockoutDuration: TimeInterval = 60 * 15                      // 15 min
    let minPasswordLength: Int = 12

    func register(email: String, password: String) async throws -> AuthResponse {
        guard password.count >= minPasswordLength else { throw AuthError.weakPassword }
        if try await repo.findUser(byEmail: email) != nil { throw AuthError.emailExists }
        let hash = await hasher.hash(password)
        let user = try await repo.createUser(email: email, passwordHash: hash)
        return try await issueTokens(for: user)
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
        let access = SessionToken(
            userID: userID,
            expiration: Date().addingTimeInterval(accessTokenLifetime)
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
