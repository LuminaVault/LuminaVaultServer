import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension AppleConsentResponse: @retroactive ResponseEncodable {}

/// Apple Ecosystem Integration P0 — per-domain data-access consent.
///   GET /v1/apple/consent  — full snapshot (every domain; absent = not allowed)
///   PUT /v1/apple/consent  — upsert one domain; disallow purges the server copy
///
/// `AppleConsentController.isAllowed(...)` is the gate every ingest endpoint and
/// Hermes Apple-tool must call before touching a domain (P0b+).
struct AppleConsentController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/consent", use: get)
        router.put("/consent", use: put)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> AppleConsentResponse {
        let tenantID = try ctx.requireIdentity().requireID()
        return try await Self.snapshot(tenantID: tenantID, fluent: fluent)
    }

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> AppleConsentResponse {
        let tenantID = try ctx.requireIdentity().requireID()
        let body = try await req.decode(as: AppleConsentUpdateRequest.self, context: ctx)
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }
        let writes = body.allowWrites ?? false
        try await sql.raw("""
        INSERT INTO apple_consent (tenant_id, domain, allowed, allow_writes, updated_at)
        VALUES (\(bind: tenantID), \(bind: body.domain.rawValue), \(bind: body.allowed), \(bind: writes), NOW())
        ON CONFLICT (tenant_id, domain) DO UPDATE
          SET allowed = EXCLUDED.allowed,
              allow_writes = EXCLUDED.allow_writes,
              updated_at = NOW()
        """).run()
        // Privacy contract: disallow = delete the synced server copy for the domain.
        if !body.allowed {
            try await Self.purgeDomain(tenantID: tenantID, domain: body.domain, sql: sql)
        }
        logger.info("apple.consent tenant=\(tenantID) domain=\(body.domain.rawValue) allowed=\(body.allowed) writes=\(writes)")
        return try await Self.snapshot(tenantID: tenantID, fluent: fluent)
    }

    // MARK: - Shared helpers

    static func snapshot(tenantID: UUID, fluent: HummingbirdFluent.Fluent) async throws -> AppleConsentResponse {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }
        struct Row: Decodable {
            let domain: String
            let allowed: Bool
            let allow_writes: Bool
            let last_sync_at: Date?
        }
        let rows = try await sql.raw("""
        SELECT domain, allowed, allow_writes, last_sync_at
        FROM apple_consent WHERE tenant_id = \(bind: tenantID)
        """).all(decoding: Row.self)
        let byDomain = Dictionary(rows.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        let consents = AppleDataDomain.allCases.map { domain -> AppleConsentDTO in
            if let r = byDomain[domain.rawValue] {
                return AppleConsentDTO(domain: domain, allowed: r.allowed, allowWrites: r.allow_writes, lastSyncAt: r.last_sync_at)
            }
            return AppleConsentDTO(domain: domain, allowed: false)
        }
        return AppleConsentResponse(consents: consents)
    }

    /// The gate: does the tenant currently allow this domain (and writes)?
    /// Fails closed (not allowed) on any error.
    static func isAllowed(tenantID: UUID, domain: AppleDataDomain, sql: any SQLDatabase) async -> (allowed: Bool, writes: Bool) {
        struct Row: Decodable { let allowed: Bool; let allow_writes: Bool }
        let row: Row? = (try? await sql.raw("""
        SELECT allowed, allow_writes FROM apple_consent
        WHERE tenant_id = \(bind: tenantID) AND domain = \(bind: domain.rawValue)
        """).first(decoding: Row.self)) ?? nil
        return (row?.allowed ?? false, row?.allow_writes ?? false)
    }

    /// Deletes the synced server copy for a domain on revoke. Per-domain data
    /// tables arrive in P1+ (Health already has its own store); wired here so
    /// revoke is honored as each domain lands. No-op until then.
    static func purgeDomain(tenantID _: UUID, domain _: AppleDataDomain, sql _: any SQLDatabase) async throws {}
}
