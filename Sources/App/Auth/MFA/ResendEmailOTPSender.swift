import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-33 production EmailOTPSender backed by the Resend HTTP API.
///
/// Wire by setting `EMAIL_KIND=resend` plus `EMAIL_RESEND_APIKEY` and
/// `EMAIL_FROM_ADDRESS` (the sender domain must be verified in Resend).
/// `EMAIL_REPLY_TO` is optional.
///
/// Delivery is best-effort: a non-2xx response throws, which propagates as
/// a 5xx out of `/v1/auth/email/start` so the iOS client can prompt the
/// user to retry rather than silently dropping the OTP.
struct ResendEmailOTPSender: EmailOTPSender {
    let apiKey: String
    let fromAddress: String
    let replyTo: String
    let session: URLSession
    let logger: Logger

    init(
        apiKey: String,
        fromAddress: String,
        replyTo: String,
        session: URLSession = .shared,
        logger: Logger,
    ) {
        self.apiKey = apiKey
        self.fromAddress = fromAddress
        self.replyTo = replyTo
        self.session = session
        self.logger = logger
    }

    func send(code: String, to email: String, purpose: String) async throws {
        guard !apiKey.isEmpty, !fromAddress.isEmpty else {
            throw HTTPError(.internalServerError, message: "resend not configured")
        }
        var body: [String: Any] = [
            "from": fromAddress,
            "to": [email],
            "subject": "Your LuminaVault verification code",
            "text": "Your LuminaVault code is \(code). It expires in 15 minutes.",
            "html": htmlBody(code: code),
        ]
        if !replyTo.isEmpty {
            body["reply_to"] = replyTo
        }

        var req = URLRequest(url: URL(string: "https://api.resend.com/emails")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(.badGateway, message: "resend: no http response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("resend \(http.statusCode): \(preview)")
            throw HTTPError(.badGateway, message: "resend email failed (\(http.statusCode))")
        }
        logger.info("email OTP delivered via resend: purpose=\(purpose) to=\(email)")
    }

    private func htmlBody(code: String) -> String {
        """
        <p>Your LuminaVault verification code:</p>
        <p style="font-size:24px;font-weight:600;letter-spacing:4px;">\(code)</p>
        <p>This code expires in 15 minutes. If you didn't request it, ignore this email.</p>
        """
    }
}
