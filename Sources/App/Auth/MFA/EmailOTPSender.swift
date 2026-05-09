import Foundation
import Logging

protocol EmailOTPSender: Sendable {
    func send(code: String, to email: String, purpose: String) async throws
}

/// Dev/local fallback. Replace with Resend/SES/SMTP impl in a follow-up phase.
struct LoggingEmailOTPSender: EmailOTPSender {
    let logger: Logger

    func send(code: String, to email: String, purpose: String) async throws {
        logger.warning("email OTP (dev only): purpose=\(purpose) to=\(email) code=\(code)")
    }
}
