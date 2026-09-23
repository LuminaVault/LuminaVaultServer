import Foundation
import LuminaVaultShared

/// An error that already knows how to explain itself to the person who hit it.
///
/// The HTTP path renders these through their own `HTTPResponseError` envelope.
/// Streaming responses cannot: once an SSE response has started the status is
/// fixed at 200, so a failure travels as an `error` event carrying a single
/// string. This is what lets a stream carry the same sentence the HTTP path
/// would have shown, instead of a generic one — and, since LuminaVaultShared
/// 5.20.0, the same code and recovery actions, so a client can offer the same
/// buttons mid-stream that it offers for the HTTP envelope.
protocol UserFacingError: Error {
    var userMessage: String { get }
    /// Machine reason, the `code` of the HTTP envelope.
    var reasonCode: String { get }
    /// The `cta` tokens of the HTTP envelope: the ways out that are real for
    /// this caller. Empty when there is nothing the user can do but retry.
    var recoveryActions: [String] { get }
}

extension UserFacingError {
    var recoveryActions: [String] {
        []
    }
}

extension UpstreamErrorResponse: UserFacingError {}
extension BYOKKeysRequiredError: UserFacingError {}
extension FreeLaneExhaustedError: UserFacingError {
    var recoveryActions: [String] {
        actions
    }
}

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

    /// The event that ends a stream failed by `error`.
    ///
    /// A user-facing error carries its code and recovery actions as
    /// `errorDetail`, which older clients still read as a plain message.
    /// Anything else is a plain `error` with the generic text: its code and
    /// description are internal.
    static func event(for error: Error) -> QueryStreamEvent {
        guard let known = error as? UserFacingError else { return .error(generic) }
        return .errorDetail(StreamErrorDTO(
            message: known.userMessage,
            code: known.reasonCode,
            cta: known.recoveryActions
        ))
    }
}
