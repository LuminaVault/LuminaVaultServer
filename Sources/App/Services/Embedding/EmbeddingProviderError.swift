import Foundation

/// HER-134 — classified embedding failures so the fallback chain can route:
/// `.transient` / `.network` → try next provider; `.permanent` → rethrow.
/// `.capExceeded` is surfaced by `EmbeddingUsageTracker` to short-circuit
/// before any provider HTTP call. `.dimMismatch` guards against a provider
/// returning a vector that doesn't match the column width.
///
/// HTTP failures carry the provider's `ProviderResponse` (status plus a short,
/// redacted error message), so a log line says why the provider refused —
/// `http=402 msg="Insufficient credits"` — instead of only `requestRejected`.
enum EmbeddingProviderError: Error, Equatable, CustomStringConvertible {
    case transient(reason: String, response: ProviderResponse? = nil)
    case network(reason: String)
    case permanent(reason: PermanentReason, response: ProviderResponse? = nil)
    case capExceeded(tenantID: UUID, monthlyTokens: Int64, cap: Int64)
    case dimMismatch(expected: Int, got: Int)

    enum PermanentReason: String, Equatable {
        case missingAPIKey
        case authRejected
        /// HTTP 402: the account is out of credit (OpenRouter "Insufficient
        /// credits"). Not `authRejected` — the fix is a top-up, not a key —
        /// and not `requestRejected`, because every call fails until then.
        case paymentRequired
        case requestRejected
        case decodeFailed
        case endpointMissing
        case providerNotRegistered
        case allProvidersFailed
    }

    /// The HTTP status and error message a provider answered with.
    struct ProviderResponse: Equatable, Sendable, CustomStringConvertible {
        static let maxMessageLength = 200

        let status: Int
        /// At most `maxMessageLength` characters, key-shaped tokens redacted.
        /// Nil when the body carried no readable message.
        let message: String?

        init(status: Int, message: String?) {
            self.status = status
            self.message = message.flatMap(Self.sanitize)
        }

        /// Reads the message out of a raw error body: the OpenAI-compatible
        /// `{"error": {"message": …}}` (OpenAI, OpenRouter), `{"error": "…"}`,
        /// a top-level `{"message": …}`, or else the body as text.
        init(status: Int, body: Data) {
            self.init(status: status, message: Self.extractMessage(from: body))
        }

        var description: String {
            guard let message else { return "http=\(status)" }
            return "http=\(status) msg=\"\(message)\""
        }

        static func extractMessage(from body: Data) -> String? {
            guard !body.isEmpty else { return nil }
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                    return message
                }
                if let error = object["error"] as? String {
                    return error
                }
                return object["message"] as? String
            }
            return String(data: body, encoding: .utf8)
        }

        /// Collapses whitespace, redacts key-shaped tokens and truncates.
        /// Providers echo a masked key on auth errors ("Incorrect API key
        /// provided: sk-abc***xyz"); masked or not, it does not belong in logs.
        static func sanitize(_ raw: String) -> String? {
            var afterBearer = false
            let words = raw.split(whereSeparator: \.isWhitespace).map { word -> String in
                let lowered = word.lowercased()
                defer { afterBearer = lowered == "bearer" }
                if afterBearer || lowered.hasPrefix("sk-") || lowered.hasPrefix("sk_") || lowered == "bearer" {
                    return "[redacted]"
                }
                return String(word)
            }
            let collapsed = words.joined(separator: " ")
            guard !collapsed.isEmpty else { return nil }
            guard collapsed.count > maxMessageLength else { return collapsed }
            return String(collapsed.prefix(maxMessageLength)) + "…"
        }
    }

    /// Maps a non-2xx answer to an error that keeps the status and the
    /// provider's message; nil for 2xx. 402 is OpenRouter's "Insufficient
    /// credits" and gets its own reason so it is not mistaken for a bad input.
    static func fromHTTP(status: Int, body: Data, providerLabel: String) -> EmbeddingProviderError? {
        let response = ProviderResponse(status: status, body: body)
        switch status {
        case 200 ..< 300:
            return nil
        case 401, 403:
            return .permanent(reason: .authRejected, response: response)
        case 402:
            return .permanent(reason: .paymentRequired, response: response)
        case 408, 429, 500 ..< 600:
            return .transient(reason: "\(providerLabel) http \(status)", response: response)
        default:
            return .permanent(reason: .requestRejected, response: response)
        }
    }

    /// True if a fallback chain should advance to the next provider.
    var isRecoverable: Bool {
        switch self {
        case .transient, .network: true
        case .permanent, .capExceeded, .dimMismatch: false
        }
    }

    /// True when the provider cannot serve any row right now — an outage, a
    /// rate limit, a missing or rejected key, an empty balance — rather than
    /// this one input being bad. The heal pass in `EmbeddingReembedService`
    /// stops and backs off on these instead of paying a call per row to learn
    /// the same thing.
    var isProviderUnavailable: Bool {
        switch self {
        case .transient, .network:
            true
        case let .permanent(reason, _):
            switch reason {
            case .missingAPIKey, .authRejected, .paymentRequired, .endpointMissing,
                 .providerNotRegistered, .allProvidersFailed:
                true
            case .requestRejected, .decodeFailed:
                false
            }
        case .capExceeded, .dimMismatch:
            false
        }
    }

    /// What the provider answered, when the failure was an HTTP response.
    var response: ProviderResponse? {
        switch self {
        case let .transient(_, response), let .permanent(_, response): response
        case .network, .capExceeded, .dimMismatch: nil
        }
    }

    /// One log-friendly line, e.g. `reason=paymentRequired http=402 msg="Insufficient credits"`.
    var description: String {
        switch self {
        case let .transient(reason, response):
            "transient reason=\"\(reason)\"" + (response.map { " \($0)" } ?? "")
        case let .network(reason):
            "network reason=\"\(reason)\""
        case let .permanent(reason, response):
            "reason=\(reason.rawValue)" + (response.map { " \($0)" } ?? "")
        case let .capExceeded(tenantID, monthlyTokens, cap):
            "capExceeded tenant=\(tenantID) used=\(monthlyTokens) cap=\(cap)"
        case let .dimMismatch(expected, got):
            "dimMismatch expected=\(expected) got=\(got)"
        }
    }
}
