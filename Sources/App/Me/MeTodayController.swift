import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-206 — `GET /v1/me/today`. Widget + daily-review aggregator. The
/// route is read-only on the caller's own tenant data; mounted with
/// JWT auth + rate-limit but no entitlement gate (mirrors HER-202
/// `/v1/health` read pattern).
struct MeTodayController {
    let service: MeTodayService
    let cache: MeTodayCache
    let logger: Logger
    /// `Cache-Control: max-age=<value>` and the LRU TTL must match so
    /// the client and server expire the same body at the same wall
    /// clock — keeps WidgetKit timelines aligned with server state.
    static let clientMaxAgeSeconds: Int = 300

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/today", use: today)
    }

    @Sendable
    func today(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let tier = user.tier // raw string column; iOS accepts "trial|pro|...".
        let ifNoneMatch = request.headers[.ifNoneMatch]

        // Cache hit path. The cached entry already carries the encoded
        // body + ETag — no service call, no re-encode, no re-hash.
        if let entry = await cache.get(tenantID: tenantID) {
            return Self.respond(entry: entry, ifNoneMatch: ifNoneMatch)
        }

        // Miss — build fresh, encode, cache, respond.
        let payload = try await service.build(tenantID: tenantID, tier: tier)
        let encoded = try Self.encoder().encode(payload)
        let etag = Self.etag(for: encoded)
        let entry = MeTodayCache.Entry(body: encoded, etag: etag, generatedAt: payload.generatedAt)
        await cache.put(tenantID: tenantID, entry: entry)
        return Self.respond(entry: entry, ifNoneMatch: ifNoneMatch)
    }

    // MARK: - Helpers

    static func respond(entry: MeTodayCache.Entry, ifNoneMatch: String?) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "private, max-age=\(clientMaxAgeSeconds)"
        headers[.eTag] = "\"\(entry.etag)\""
        // RFC 7232: clients send the value verbatim, including quotes.
        // Strip them before equality so an identical hash matches.
        let inboundETag = ifNoneMatch?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if inboundETag == entry.etag {
            return Response(status: .notModified, headers: headers)
        }
        return Response(
            status: .ok,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: entry.body)),
        )
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Weak-ETag style hash. The leading `W/` is intentionally omitted —
    /// our cache stores byte-identical bodies, so a strong validator is
    /// accurate. SHA-256 hex truncated to 16 chars keeps the header
    /// small while remaining collision-resistant for per-tenant payloads.
    static func etag(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
