import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// Structured per-request logging with outcome + timing — the line you grep
/// when debugging prod. Replaces Hummingbird's `LogRequestsMiddleware`, which
/// only logs `method`+`path` at request START (no status, no duration, no
/// error), so a failing request leaves nothing useful in the log.
///
/// Correlation comes for free from the middleware registered before this one:
/// Hummingbird stamps `hb.request.id` onto `context.logger`, and
/// `TracingMiddleware` adds trace/span ids. So every line here joins up with
/// per-handler logs (e.g. `loggedStage`) and exported OTel traces by id.
///
/// Levels by outcome so noisy 4xx don't drown real failures and 5xx page:
/// `5xx → .error`, `4xx → .notice`, otherwise the configured success level
/// (default `.info`). Thrown `HTTPError`s are caught, logged with their status
/// + redacted message, then rethrown unchanged — the router still builds the
/// response from the same error.
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    let successLevel: Logger.Level

    init(successLevel: Logger.Level = .info) {
        self.successLevel = successLevel
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let start = ContinuousClock.now
        // `path` only (never `uri`) — query strings can carry tokens/PII.
        let method = request.method.rawValue
        let path = request.uri.path

        context.logger.debug("request received", metadata: [
            "method": .string(method),
            "path": .string(path),
        ])

        do {
            let response = try await next(request, context)
            let code = response.status.code
            context.logger.log(level: Self.level(forStatus: code, success: successLevel), "request", metadata: [
                "method": .string(method),
                "path": .string(path),
                "status": .stringConvertible(code),
                "duration_ms": .stringConvertible(Self.elapsedMs(since: start)),
            ])
            return response
        } catch {
            // Thrown errors haven't been turned into a Response yet; recover the
            // status the router will emit so the log matches what the client sees.
            let status = (error as? HTTPError)?.status ?? .internalServerError
            let code = status.code
            context.logger.log(level: Self.level(forStatus: code, success: successLevel), "request failed", metadata: [
                "method": .string(method),
                "path": .string(path),
                "status": .stringConvertible(code),
                "duration_ms": .stringConvertible(Self.elapsedMs(since: start)),
                "error_type": .string(String(describing: type(of: error))),
                "error": .string(Logger.redact(String(describing: error))),
            ])
            throw error
        }
    }

    private static func level(forStatus code: Int, success: Logger.Level) -> Logger.Level {
        if code >= 500 {
            return .error
        }
        if code >= 400 {
            return .notice
        }
        return success
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int64 {
        let d = ContinuousClock.now - start
        return Int64(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}
