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
/// payment required.
///
/// The CTAs and the sentence both come from `actions`, which the router
/// decides from the caller's tier and mode (`FreeLanePolicy.recoveryActions`).
/// A free or lapsed user can pay or bring a key. A paying user reaches the
/// lane only by choosing BYOK without a key, or during an outage, and telling
/// them to upgrade would name something they already have.
///
/// The message deliberately names no model or provider: the free lane runs as
/// managed mode, and `ModelDisclosurePolicy` hides model identity for managed
/// requests. An error string is just another place identity can leak.
struct FreeLaneExhaustedError: Error, Equatable, HTTPResponseError {
    let reasonCode = "free_lane_exhausted"
    let retryAfterSeconds: Int
    var actions: [String] = ["upgrade", "add_key"]

    var userMessage: String {
        let spent = "You've used today's free messages."
        if actions.contains("upgrade") {
            return "\(spent) Upgrade for the full brain, or add your own API key in Settings to keep going now."
        }
        if actions.contains("switch_to_managed") {
            return "\(spent) Switch to Managed, or add your own API key in Settings to keep going now."
        }
        return "\(spent) Add your own API key in Settings to keep going now."
    }

    var status: HTTPResponse.Status {
        .tooManyRequests
    }

    var bodyData: Data {
        let envelope: [String: Any] = [
            "error": [
                "code": reasonCode,
                "message": userMessage,
                "cta": actions,
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
