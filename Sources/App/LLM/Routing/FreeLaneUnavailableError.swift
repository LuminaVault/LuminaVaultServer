import Foundation
import HTTPTypes
import Hummingbird

/// The free lane was the only legal route, and it cannot serve anyone: no
/// platform key for any of its legs loaded.
///
/// This used to be reported as `FreeLaneExhaustedError` — "You've used today's
/// free messages", 429, a reset timer — to people who had used none. A
/// misconfiguration presented itself as a quota. It is its own condition now:
///
/// - **503**, because the service cannot answer, not because the caller did
///   too much.
/// - **No `Retry-After` and no `retryAfterSeconds`.** Nothing resets at
///   midnight; promising a time would be another invention.
/// - **Actions that are real for this caller**, decided by the router from
///   their tier and mode (`FreeLanePolicy.recoveryActions`): an upgrade only
///   when upgrading would actually unlock paid inference, managed only when it
///   is available to them.
///
/// Like `FreeLaneExhaustedError`, the message names no model or provider.
struct FreeLaneUnavailableError: Error, Equatable, HTTPResponseError {
    let reasonCode = "free_lane_unavailable"
    let actions: [String]
    let userMessage =
        "Free messages are unavailable right now. Add your own API key in Settings to keep going."

    var status: HTTPResponse.Status {
        .serviceUnavailable
    }

    var bodyData: Data {
        let envelope: [String: Any] = [
            "error": [
                "code": reasonCode,
                "message": userMessage,
                "cta": actions,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: bodyData))
        )
    }
}

extension FreeLaneUnavailableError: UserFacingError {
    var recoveryActions: [String] {
        actions
    }
}
