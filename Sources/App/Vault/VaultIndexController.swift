import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent

extension VaultIndexStatus: ResponseEncodable {}
extension VaultContextPacket: ResponseEncodable {}
extension VaultLinksResponse: ResponseEncodable {}
extension VaultLintReport: ResponseEncodable {}

/// Outgoing and incoming links for one document.
struct VaultLinksResponse: Codable, Sendable {
    let vaultFileID: UUID
    let path: String
    let outgoing: [OutgoingLinkRow]
    let incoming: [IncomingLinkRow]
}

/// Read-only index inspection: freshness, context packets, and the link graph.
///
/// Mounted at `/v1/vault` behind JWT. Every route here is a pure read — none
/// of them index, embed, re-resolve, or otherwise create state as a side
/// effect of being called. That is a contract, not an implementation detail:
/// once an agent can call these, "retrieval never writes" is the only thing
/// making them safe to expose.
///
/// Naming note: `GET /v1/vault/status` was already taken by vault
/// *provisioning* state (has this tenant's vault been created?), which is a
/// different question, so index freshness lives at `GET /v1/vault/index`.
struct VaultIndexController {
    let fluent: Fluent
    let status: VaultIndexStatusService
    let navigation: VaultNavigationService
    let links: VaultLinkRepository
    let lint: VaultLintService
    let vaultAccess: VaultAccessService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/index", use: indexStatus)
        router.get("/context/:vaultFileID", use: context)
        router.get("/links/:vaultFileID", use: documentLinks)
        router.get("/lint", use: lintVault)
    }

    /// Health checks over the vault and its index.
    ///
    /// A GET, not a POST, because it changes nothing — the linter reads files
    /// and index rows and never rewrites either.
    @Sendable
    func lintVault(_ request: Request, ctx: AppRequestContext) async throws -> VaultLintReport {
        let tenantID = try await vaultAccess.resolve(request: request, context: ctx, requiring: .read).vaultID
        return try await lint.lint(tenantID: tenantID)
    }

    /// Is the retrievable index up to date with the vault?
    @Sendable
    func indexStatus(_ request: Request, ctx: AppRequestContext) async throws -> VaultIndexStatus {
        let tenantID = try await vaultAccess.resolve(request: request, context: ctx, requiring: .read).vaultID
        return try await status.status(tenantID: tenantID)
    }

    /// Deterministic evidence packet for one document.
    @Sendable
    func context(_ request: Request, ctx: AppRequestContext) async throws -> VaultContextPacket {
        let tenantID = try await vaultAccess.resolve(request: request, context: ctx, requiring: .read).vaultID
        let vaultFileID = try Self.parseVaultFileID(ctx)
        let siblingLimit = request.uri.queryParameters.get("siblingLimit").flatMap { Int($0) }
            ?? VaultNavigationService.defaultSiblingLimit
        return try await navigation.context(
            tenantID: tenantID,
            vaultFileID: vaultFileID,
            siblingLimit: siblingLimit
        )
    }

    /// Outgoing links and backlinks for one document.
    @Sendable
    func documentLinks(_ request: Request, ctx: AppRequestContext) async throws -> VaultLinksResponse {
        let tenantID = try await vaultAccess.resolve(request: request, context: ctx, requiring: .read).vaultID
        let vaultFileID = try Self.parseVaultFileID(ctx)
        guard let file = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == vaultFileID).first()
        else {
            throw HTTPError(.notFound, message: "no vault file with that id")
        }
        let outgoing = try await links.outgoing(tenantID: tenantID, vaultFileID: vaultFileID)
        let incoming = try await links.incoming(tenantID: tenantID, vaultFileID: vaultFileID)
        return VaultLinksResponse(
            vaultFileID: vaultFileID,
            path: file.path,
            outgoing: outgoing,
            incoming: incoming
        )
    }

    private static func parseVaultFileID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("vaultFileID"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid vaultFileID")
        }
        return id
    }
}
