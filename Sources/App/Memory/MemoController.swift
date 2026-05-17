import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

extension MemoResponse: ResponseEncodable {}
extension MemoListResponse: ResponseEncodable {}

struct MemoController {
    let service: MemoGeneratorService
    let fluent: Fluent

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: generate)
        router.get("", use: list)
    }

    @Sendable
    func generate(_ req: Request, ctx: AppRequestContext) async throws -> MemoResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: MemoRequest.self, context: ctx)
        let result = try await service.generate(
            tenantID: user.requireID(),
            profileUsername: user.username,
            topic: body.topic,
            hint: body.hint,
            save: body.save ?? true,
        )
        return MemoResponse(
            memo: result.memo,
            path: result.path,
            sourceMemoryIds: result.sourceMemoryIDs,
            summary: result.summary,
        )
    }

    /// GET /v1/memos — list memos saved under `memos/<date>/<slug>.md` for
    /// the caller's tenant. Returns most-recent first. Title is derived
    /// from the file slug (path stem) until a richer memo index exists.
    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> MemoListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let rows = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$path, .custom("LIKE"), "memos/%")
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()
        let memos = rows.compactMap { row -> MemoSummaryDTO? in
            guard let id = row.id, let createdAt = row.createdAt else { return nil }
            return MemoSummaryDTO(
                id: id,
                title: Self.titleFromPath(row.path),
                path: row.path,
                createdAt: createdAt,
                summary: nil,
            )
        }
        return MemoListResponse(memos: memos)
    }

    /// `memos/2026-05-17/sleep-patterns.md` → "Sleep Patterns".
    static func titleFromPath(_ path: String) -> String {
        let stem = (path as NSString).lastPathComponent
        let withoutExt = (stem as NSString).deletingPathExtension
        return withoutExt
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
