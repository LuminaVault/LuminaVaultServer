import Hummingbird
import HummingbirdCompression

/// Wraps `HummingbirdCompression.ResponseCompressionMiddleware` and skips
/// compression for Server-Sent Events.
///
/// The stock middleware decides whether to compress purely from the request's
/// `Accept-Encoding` and the response `content-length`. A streaming SSE body has
/// no content-length (`nil`), so the size guard is skipped and the response gets
/// gzipped anyway. The zlib compressor then buffers every `data:` frame inside its
/// 32 KB window and only flushes at stream end — so the client receives the whole
/// reply in one burst instead of token-by-token, defeating the live typewriter.
///
/// `URLSession` always sends `Accept-Encoding: gzip`, so this bites every iOS
/// chat turn. The fix: detect `text/event-stream` responses and return them
/// uncompressed; everything else delegates to the stock compression logic
/// unchanged.
struct SSEAwareResponseCompressionMiddleware<Context: RequestContext>: RouterMiddleware {
    let base: ResponseCompressionMiddleware<Context>

    init(minimumResponseSizeToCompress: Int) {
        base = ResponseCompressionMiddleware(minimumResponseSizeToCompress: minimumResponseSizeToCompress)
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        // SSE must stream frame-by-frame; compressing it buffers the whole body.
        if response.headers[.contentType]?.hasPrefix("text/event-stream") == true {
            return response
        }
        // Delegate to the stock middleware, feeding it the already-computed
        // response so `next` is only ever invoked once.
        return try await base.handle(request, context: context) { _, _ in response }
    }
}
