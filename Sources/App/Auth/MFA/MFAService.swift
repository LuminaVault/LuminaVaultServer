import Crypto
import FluentKit
import Foundation
import HummingbirdFluent

protocol MFAService: Sendable {
    /// Issues a new email OTP challenge for a user. Returns the challenge ID
    /// (clients submit this back along with the code).
    func issue(forUser user: User, purpose: String) async throws -> UUID

    /// Verifies a submitted code against an active challenge.
    /// Returns true if accepted; on failure increments attempts (max 5 → consumed).
    func verify(challengeID: UUID, code: String) async throws -> Bool
}

struct DefaultMFAService: MFAService {
    let fluent: Fluent
    let sender: any EmailOTPSender
    let generator: any OTPCodeGenerator
    let challengeLifetime: TimeInterval = 60 * 5     // 5 min
    let maxFailedAttempts: Int = 5

    func issue(forUser user: User, purpose: String = "login") async throws -> UUID {
        let tenantID = try user.requireID()
        let code = generator.generate()
        let row = MFAChallenge(
            tenantID: tenantID,
            purpose: purpose,
            channel: "email",
            destination: user.email,
            codeHash: sha256Hex(code),
            expiresAt: Date().addingTimeInterval(challengeLifetime)
        )
        row.lastSentAt = Date()
        try await row.save(on: fluent.db())
        try await sender.send(code: code, to: user.email, purpose: purpose)
        return try row.requireID()
    }

    func verify(challengeID: UUID, code: String) async throws -> Bool {
        guard let row = try await MFAChallenge.find(challengeID, on: fluent.db()) else {
            return false
        }
        if row.consumedAt != nil { return false }
        if row.expiresAt < Date() { return false }
        if row.failedAttempts >= maxFailedAttempts { return false }

        if row.codeHash == sha256Hex(code) {
            row.consumedAt = Date()
            try await row.save(on: fluent.db())
            return true
        } else {
            row.failedAttempts += 1
            if row.failedAttempts >= maxFailedAttempts {
                row.consumedAt = Date()    // burn the challenge
            }
            try await row.save(on: fluent.db())
            return false
        }
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
