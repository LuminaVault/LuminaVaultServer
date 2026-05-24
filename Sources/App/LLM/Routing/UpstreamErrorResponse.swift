import Foundation
import Hummingbird

/// HER-240 — Structured error envelope for LLM upstream failures.
/// Replaces the opaque `HTTPError(.badGateway, message:)` path so
/// clients can programmatically distinguish timeout vs unreachable
/// vs rejected.
///
/// Wire format:
///   { "error": { "code": "upstream_timeout",
///                "message": "Hermes timed out responding.",
///                "retry_after_ms": 2000 } }
///
/// Status mapping:
///   - `upstream_timeout`  → 504 Gateway Timeout
///   - everything else     → 502 Bad Gateway
struct UpstreamErrorResponse: Error, HTTPResponseError {
    let reasonCode: String
    let userMessage: String
    let retryAfterMs: Int?

    init(reasonCode: String, userMessage: String, retryAfterMs: Int? = nil) {
        self.reasonCode = reasonCode
        self.userMessage = userMessage
        self.retryAfterMs = retryAfterMs
    }

    /// Hint emitted on `upstream_timeout` envelopes so clients know how
    /// long to wait before retrying. Matches the adapter's per-request
    /// retry sleep so client + server back off in lockstep.
    static let timeoutRetryHintMs: Int = 2000

    /// Reason code → HTTP status mapping. Keep in sync with
    /// `ProviderError.reasonCode` cases.
    var status: HTTPResponse.Status {
        switch reasonCode {
        case "upstream_timeout": .gatewayTimeout
        default: .badGateway
        }
    }

    /// Pre-serialized JSON body. Exposed as `internal` so tests can
    /// inspect the envelope without constructing a full HTTP response.
    var bodyData: Data {
        var payload: [String: Any] = [
            "code": reasonCode,
            "message": userMessage,
        ]
        if let retryAfterMs {
            payload["retry_after_ms"] = retryAfterMs
        }
        let envelope: [String: Any] = ["error": payload]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: bodyData)),
        )
    }
}
