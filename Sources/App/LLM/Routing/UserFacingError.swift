import Foundation

/// An error that already knows how to explain itself to the person who hit it.
///
/// The HTTP path renders these through their own `HTTPResponseError` envelope.
/// Streaming responses cannot: once an SSE response has started the status is
/// fixed at 200, so a failure travels as an `error` event carrying a single
/// string. This is what lets a stream carry the same sentence the HTTP path
/// would have shown, instead of a generic one.
protocol UserFacingError: Error {
    var userMessage: String { get }
}

extension UpstreamErrorResponse: UserFacingError {}
extension BYOKKeysRequiredError: UserFacingError {}
extension FreeLaneExhaustedError: UserFacingError {}
extension UsageCapExceededError: UserFacingError {}

enum StreamErrorMessage {
    /// What an SSE `error` event should say for `error`.
    ///
    /// Anything that has a user-facing explanation gets it. Anything else is an
    /// internal failure whose details must not reach the client, so it stays
    /// generic — the real error is logged server-side by the caller.
    static let generic = "upstream failure"

    static func forClient(_ error: Error) -> String {
        (error as? UserFacingError)?.userMessage ?? generic
    }
}
