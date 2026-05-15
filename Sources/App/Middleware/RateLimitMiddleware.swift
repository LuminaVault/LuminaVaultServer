import Foundation
import Hummingbird

/// Per-route rate-limit policy.
struct RateLimitPolicy {
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
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        let key = "rl:" + policy.keyBuilder(request, context)
        let now = Date().timeIntervalSince1970

        let current: BucketState = await (try? storage.get(key: key, as: BucketState.self))
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
                message: "rate limit exceeded",
            )
        }
        return try await next(request, context)
    }
}

private struct BucketState: Codable {
    var start: TimeInterval
    var count: Int
}

extension RateLimitPolicy {
    /// Best-effort client IP from common proxy headers. Internal so the
    /// `userOrIP` keyer below (and tests) can reuse it.
    @Sendable
    static func ipKey(_ req: Request) -> String {
        if let xff = req.headers[.init("x-forwarded-for")!] {
            return String(xff.split(separator: ",").first ?? "anon")
                .trimmingCharacters(in: .whitespaces)
        }
        if let real = req.headers[.init("x-real-ip")!] { return real }
        return "anon"
    }

    /// Per-tenant key for authenticated routes; falls back to per-IP when
    /// no identity is attached so the same policy works on auth-optional
    /// surfaces. Bucket prefixes (`u:` / `ip:`) keep the two namespaces
    /// disjoint so a UUID never collides with an IP literal.
    @Sendable
    static func userOrIPKey(_ req: Request, _ ctx: AppRequestContext) -> String {
        if let id = ctx.identity?.id?.uuidString {
            return "u:" + id
        }
        return "ip:" + ipKey(req)
    }

    static let registerByIP = RateLimitPolicy(max: 5, window: 60) { req, _ in ipKey(req) }
    static let loginByIP = RateLimitPolicy(max: 10, window: 60) { req, _ in ipKey(req) }
    static let forgotPasswordByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let resendResetByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let resetPasswordByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let refreshByIP = RateLimitPolicy(max: 30, window: 60) { req, _ in ipKey(req) }
    static let mfaVerifyByIP = RateLimitPolicy(max: 20, window: 60) { req, _ in ipKey(req) }
    static let mfaResendByIP = RateLimitPolicy(max: 10, window: 60) { req, _ in ipKey(req) }
    static let sendVerifyByIP = RateLimitPolicy(max: 5, window: 300) { req, _ in ipKey(req) }
    static let confirmEmailByIP = RateLimitPolicy(max: 10, window: 300) { req, _ in ipKey(req) }

    /// HER-94: Per-user policies for protected, capacity-sensitive routes.
    /// Keyed via `userOrIPKey` so a single bad actor with one account cannot
    /// burn the shared per-IP bucket for everyone behind the same NAT, while
    /// still degrading gracefully if the route is ever called unauth'd.
    static let chatByUser = RateLimitPolicy(max: 30, window: 60, keyBuilder: userOrIPKey)
    static let kbCompileByUser = RateLimitPolicy(max: 5, window: 60, keyBuilder: userOrIPKey)
    static let captureByUser = RateLimitPolicy(max: 60, window: 60, keyBuilder: userOrIPKey)
    static let vaultUploadByUser = RateLimitPolicy(max: 30, window: 60, keyBuilder: userOrIPKey)
    /// HER-91: vault export streams the entire tenant tree. Expensive on
    /// disk + bandwidth, so cap at a handful per 5-minute window per user.
    static let vaultExportByUser = RateLimitPolicy(max: 3, window: 300, keyBuilder: userOrIPKey)
    /// HER-85: SOUL.md is small but writes hit two filesystem paths and could
    /// be abused to spam Hermes profile dirs. Cheap per-user bucket.
    static let soulByUser = RateLimitPolicy(max: 30, window: 60, keyBuilder: userOrIPKey)

    /// HER-148: each skill run can fan out to Hermes (one or more LLM calls)
    /// plus filesystem and DB writes. Cap manual `/v1/skills/:name/run`
    /// invocations so a user can't burn their daily Mtok budget by hammering
    /// the endpoint. Cron-/event-triggered runs bypass this middleware.
    /// Final window/max numbers to be tuned in HER-148 sub-tickets.
    static let skillRunByUser = RateLimitPolicy(max: 10, window: 60, keyBuilder: userOrIPKey)

    /// HER-196 — `/v1/achievements` and `/v1/achievements/recent` are
    /// read-only catalog joins; iOS pulls them on Settings → Forms enter
    /// and again on push receipt. 60/min/user covers both legitimate
    /// patterns with margin and shuts off polling abuse.
    static let achievementsByUser = RateLimitPolicy(max: 60, window: 60, keyBuilder: userOrIPKey)

    /// HER-137: phone OTP start. Each call burns an SMS, which costs real
    /// money — toll-fraud bots target this surface. Stacked policies:
    /// 3/min catches burst attempts, 10/day caps the daily SMS budget per IP.
    /// Apply BOTH on the `/v1/auth/phone/start` route.
    static let phoneStartByIPPerMinute = RateLimitPolicy(max: 3, window: 60) { req, _ in ipKey(req) }
    static let phoneStartByIPDaily = RateLimitPolicy(max: 10, window: 86400) { req, _ in ipKey(req) }

    /// HER-138: email magic-link start. SES/Mailgun spend is equally toll-
    /// fraud-able as SMS; abusers can also weaponize the endpoint to spam
    /// arbitrary inboxes with OTPs. Mirror the phone policy: 3/min burst
    /// + 10/day budget, both per IP. Apply BOTH on
    /// `/v1/auth/email/start`.
    static let emailMagicStartByIPPerMinute = RateLimitPolicy(max: 3, window: 60) { req, _ in ipKey(req) }
    static let emailMagicStartByIPDaily = RateLimitPolicy(max: 10, window: 86400) { req, _ in ipKey(req) }

    /// HER-203: `POST /v1/transcribe` (STT). Each call burns upstream
    /// Whisper-provider seconds-of-audio quota — Groq/OpenAI bill by
    /// transcribed second, so capping protects provider spend per user.
    /// Stacked policies: 10/min covers normal voice-memo bursts, 200/day
    /// bounds the daily provider bill per tenant. Apply BOTH on
    /// `/v1/transcribe`.
    static let transcribeByUserPerMinute = RateLimitPolicy(max: 10, window: 60, keyBuilder: userOrIPKey)
    static let transcribeByUserDaily = RateLimitPolicy(max: 200, window: 86400, keyBuilder: userOrIPKey)

    /// HER-204: POST /v1/tts. Stacked policies mirroring SMS/email-magic-link
    /// shape — 30/min burst catches abuse, 1000/day caps the per-user budget.
    /// Both keyed per-user (falls back to per-IP when auth degrades).
    static let ttsByUserPerMinute = RateLimitPolicy(max: 30, window: 60, keyBuilder: userOrIPKey)
    static let ttsByUserDaily = RateLimitPolicy(max: 1000, window: 86400, keyBuilder: userOrIPKey)
}
