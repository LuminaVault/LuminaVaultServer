import Foundation
import HTTPTypes
import Hummingbird

/// The free lane was the only legal route and its daily allowance is spent.
///
/// Modelled on `BYOKKeysRequiredError` so it renders through the same
/// `HTTPResponseError` path and the same `{error:{code,message,cta}}` envelope
/// the rest of the routing layer uses.
///
/// 429 rather than 402: the allowance resets, so this is rate limiting, not
/// payment required. The two CTAs are the two real ways out — pay us, or bring
/// a key and stop being rate limited at all.
///
/// The message deliberately names no model or provider: the free lane runs as
/// managed mode, and `ModelDisclosurePolicy` hides model identity for managed
/// requests. An error string is just another place identity can leak.
struct FreeLaneExhaustedError: Error, Equatable, HTTPResponseError {
    let reasonCode = "free_lane_exhausted"
    let retryAfterSeconds: Int
    let userMessage =
        "You've used today's free messages. Upgrade for the full brain, or add your own API key in Settings to keep going now."

    init(retryAfterSeconds: Int) {
        self.retryAfterSeconds = retryAfterSeconds
    }

    var status: HTTPResponse.Status { .tooManyRequests }

    var bodyData: Data {
        let envelope: [String: Any] = [
            "error": [
                "code": reasonCode,
                "message": userMessage,
                "cta": ["upgrade", "add_key"],
                "retryAfterSeconds": retryAfterSeconds,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.retryAfter] = String(retryAfterSeconds)
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: bodyData))
        )
    }
}
