import Foundation
import Hummingbird

/// Per-route rate-limit policy.
struct RateLimitPolicy: Sendable {
    let max: Int
    let window: TimeInterval
    /// Builds the bucket key from the request + context. Use IP, tenantID,
    /// (IP, email), etc. depending on what the route is rate-limiting.
    let keyBuilder: @Sendable (Request, AppRequestContext) -> String
}

/// Token-bucket rate limiter on top of any `PersistDriver`. Hummingbird
/// has no built-in rate limiter — `MemoryPersistDriver` works for a
/// single process; swap to a Redis-backed `PersistDriver` for clusters.
struct RateLimitMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    let policy: RateLimitPolicy
    let storage: any PersistDriver

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let key = "rl:" + policy.keyBuilder(request, context)
        let now = Date().timeIntervalSince1970

        let current: BucketState = (try? await storage.get(key: key, as: BucketState.self))
            ?? BucketState(start: now, count: 0)
        var bucket = current
        if now - bucket.start > policy.window {
            bucket = BucketState(start: now, count: 0)
        }
        bucket.count += 1

        let ttl = Duration.seconds(Int(policy.window) + 5)
        try await storage.set(key: key, value: bucket, expires: ttl)

        if bucket.count > policy.max {
            let retryAfter = max(1, Int(policy.window - (now - bucket.start)))
            throw HTTPError(
                .tooManyRequests,
                headers: [.retryAfter: String(retryAfter)],
                message: "rate limit exceeded"
            )
        }
        return try await next(request, context)
    }
}

private struct BucketState: Codable, Sendable {
    var start: TimeInterval
    var count: Int
}

extension RateLimitPolicy {
    /// Best-effort client IP from common proxy headers.
    @Sendable
    private static func ipKey(_ req: Request) -> String {
        if let xff = req.headers[.init("x-forwarded-for")!] {
            return String(xff.split(separator: ",").first ?? "anon")
                .trimmingCharacters(in: .whitespaces)
        }
        if let real = req.headers[.init("x-real-ip")!] { return real }
        return "anon"
    }

    static let registerByIP = RateLimitPolicy(max: 5, window: 60) { req, _ in ipKey(req) }
    static let loginByIP = RateLimitPolicy(max: 10, window: 60) { req, _ in ipKey(req) }
    static let forgotPasswordByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let resendResetByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let resetPasswordByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let refreshByIP = RateLimitPolicy(max: 30, window: 60) { req, _ in ipKey(req) }
    static let mfaVerifyByIP = RateLimitPolicy(max: 20, window: 60) { req, _ in ipKey(req) }
    static let mfaResendByIP = RateLimitPolicy(max: 10, window: 60) { req, _ in ipKey(req) }
}
