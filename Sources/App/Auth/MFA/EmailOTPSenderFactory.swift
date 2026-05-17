import Foundation
import Logging

/// HER-33 — selects the right `EmailOTPSender` impl from the `EMAIL_KIND`
/// env knob. Mirrors `makeSMSSender` (SMS factory).
///
/// `logging` (default) — dev/CI fallback that writes the OTP to the log.
/// `resend`           — production HTTP transport (`ResendEmailOTPSender`).
///
/// Unknown values fall back to `LoggingSMSSender` after a warning so a
/// typo in compose never bricks auth in dev. Production deploys should
/// explicitly set `EMAIL_KIND=resend` and verify with a smoke email.
func makeEmailOTPSender(
    kind: String,
    apiKey: String,
    fromAddress: String,
    replyTo: String,
    logger: Logger,
) -> any EmailOTPSender {
    switch kind.lowercased() {
    case "resend":
        return ResendEmailOTPSender(
            apiKey: apiKey,
            fromAddress: fromAddress,
            replyTo: replyTo,
            logger: logger,
        )
    case "", "logging":
        return LoggingEmailOTPSender(logger: logger)
    default:
        logger.warning("unknown email.kind=\(kind); falling back to LoggingEmailOTPSender")
        return LoggingEmailOTPSender(logger: logger)
    }
}
