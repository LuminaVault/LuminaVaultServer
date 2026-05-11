import Foundation
import Logging

protocol SMSSender: Sendable {
    /// `phone` MUST be E.164. `purpose` mirrors the EmailOTPSender shape so
    /// dashboards can join the two surfaces.
    func send(code: String, to phone: String, purpose: String) async throws
}

/// Dev / CI fallback. Logs the OTP at warning level so it's grep-able from
/// `docker logs hermes-hummingbird | grep lv.sms`. Use `TwilioSMSSender` in
/// production by setting `SMS_KIND=twilio`.
struct LoggingSMSSender: SMSSender {
    let logger: Logger

    func send(code: String, to phone: String, purpose: String) async throws {
        logger.warning("sms OTP (dev only): purpose=\(purpose) to=\(phone) code=\(code)")
    }
}
