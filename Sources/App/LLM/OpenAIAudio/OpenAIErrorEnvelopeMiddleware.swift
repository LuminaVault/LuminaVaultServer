import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Normalises every failure on `/v1/audio/*` into OpenAI's error envelope.
///
/// Callers on this surface are OpenAI SDK clients. The SDK builds
/// `APIStatusError.message` from `body["error"]["message"]`, and Hermes
/// relays that message to the end user — so the envelope is what decides
/// whether someone on Telegram reads "you've used today's voice" or
/// `Error code: 429 - {...}`.
///
/// Two different failure shapes have to be caught, which is why this is a
/// middleware rather than controller-local error handling:
///
///  - `RateLimitMiddleware` **throws** `HTTPError`. Hummingbird already
///    renders that as `{"error":{"message":…}}`, which is close but carries
///    no `type`.
///  - `EntitlementMiddleware` **returns** a 402 `Response` whose body is
///    `{"paywall": true, …}` — not OpenAI-shaped at all, and the SDK would
///    surface the raw JSON.
///
/// Mount this OUTERMOST on the group so it wraps the other middleware.
struct OpenAIErrorEnvelopeMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            let response = try await next(request, context)
            guard response.status.code >= 400 else { return response }
            // A downstream middleware returned (not threw) a failure.
            return Self.encode(
                Self.envelope(status: response.status, message: nil),
                status: response.status,
                headers: response.headers
            )
        } catch let error as HTTPError {
            return Self.encode(
                Self.envelope(status: error.status, message: error.body),
                status: error.status,
                headers: error.headers
            )
        }
        // Anything else propagates untouched: unknown errors should surface
        // as the framework's opaque 500 rather than be dressed up as a
        // well-understood OpenAI failure.
    }

    /// Maps an HTTP status onto OpenAI's `type` taxonomy, keeping whatever
    /// prose the thrower supplied.
    static func envelope(status: HTTPResponse.Status, message: String?) -> OpenAIErrorEnvelope {
        switch status.code {
        case 401, 403:
            .authentication(message ?? "Not authorized for this audio endpoint.")
        case 402:
            // Reached only when the tier has no voice allowance at all.
            .insufficientQuota(
                message ?? "Voice is not available on this plan."
            )
        case 413:
            .invalidRequest(
                message ?? "Audio file is too large.",
                code: "file_too_large"
            )
        case 415:
            .invalidRequest(message ?? "Unsupported audio format.", code: "unsupported_format")
        case 429:
            .rateLimit(
                message ?? "You have reached the voice limit for now. Try again later."
            )
        case 400 ..< 500:
            .invalidRequest(message ?? status.reasonPhrase)
        case 501:
            // Spoken replies, until that milestone ships.
            .server(message ?? "This audio capability is not enabled.", code: "not_implemented")
        case 502, 503, 504:
            .server(message ?? "The speech service is temporarily unavailable.", code: "upstream_error")
        default:
            .server(message ?? status.reasonPhrase)
        }
    }

    /// Encodes the envelope, preserving transport headers that carry meaning
    /// (notably `Retry-After` from the rate limiter) while replacing the body
    /// and its content type.
    static func encode(
        _ envelope: OpenAIErrorEnvelope,
        status: HTTPResponse.Status,
        headers: HTTPFields
    ) -> Response {
        var outHeaders = HTTPFields()
        if let retryAfter = headers[.retryAfter] {
            outHeaders[.retryAfter] = retryAfter
        }
        outHeaders[.contentType] = "application/json; charset=utf-8"

        let data = (try? JSONEncoder().encode(envelope))
            ?? Data(#"{"error":{"message":"Unknown error","type":"server_error"}}"#.utf8)

        return Response(
            status: status,
            headers: outHeaders,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
