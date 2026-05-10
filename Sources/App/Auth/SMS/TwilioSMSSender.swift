import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Calls the Twilio Messages API. Auth is HTTP Basic with the account SID
/// and auth token. Body uses x-www-form-urlencoded per Twilio's contract.
///
/// Wire by setting `SMS_KIND=twilio` plus `TWILIO_ACCOUNT_SID`,
/// `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` (E.164).
struct TwilioSMSSender: SMSSender {
    let accountSID: String
    let authToken: String
    let fromNumber: String
    let session: URLSession
    let logger: Logger

    init(accountSID: String, authToken: String, fromNumber: String, session: URLSession = .shared, logger: Logger) {
        self.accountSID = accountSID
        self.authToken = authToken
        self.fromNumber = fromNumber
        self.session = session
        self.logger = logger
    }

    func send(code: String, to phone: String, purpose: String) async throws {
        guard !accountSID.isEmpty, !authToken.isEmpty, !fromNumber.isEmpty else {
            throw HTTPError(.internalServerError, message: "twilio not configured")
        }
        let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSID)/Messages.json")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let credentials = "\(accountSID):\(authToken)".data(using: .utf8)!.base64EncodedString()
        req.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = Self.urlEncode([
            "To": phone,
            "From": fromNumber,
            "Body": "Your LuminaVault code is \(code). Expires in 5 min."
        ])
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(.badGateway, message: "twilio: no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("twilio \(http.statusCode): \(preview)")
            throw HTTPError(.badGateway, message: "twilio sms failed (\(http.statusCode))")
        }
        logger.info("sms delivered via twilio: purpose=\(purpose) to=\(phone)")
    }

    private static func urlEncode(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
