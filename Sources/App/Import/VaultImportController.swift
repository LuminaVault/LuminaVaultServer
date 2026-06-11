import Foundation
import Hummingbird
import Logging

/// `POST /v1/import/vault-bulk` — bulk-ingest external markdown (a user's
/// Hermes/Obsidian vault) into one Space. Body: `{ space, files: [{path,
/// content}] }`. Reuses `VaultIngestService` (vault_file + memory + embedding +
/// dedup). The zip-upload + folder-pick UI is a thin wrapper on top of this;
/// this JSON form is also drivable directly (e.g. a VPS push-sync script).
struct VaultImportController {
    let ingest: VaultIngestService
    /// Guards against an unbounded single request; large vaults import in
    /// batches.
    let maxFilesPerRequest = 2000

    struct BulkRequest: Decodable {
        let space: String
        let files: [VaultIngestService.FileInput]
    }

    struct BulkResponse: Codable, ResponseEncodable {
        let spaceID: String
        let spaceSlug: String
        let imported: Int
        let skipped: Int
        let failed: Int
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("vault-bulk", use: bulk)
    }

    /// 96 MB — a vault batch of markdown is far larger than the default decode
    /// cap, so collect the body explicitly.
    let maxBodyBytes = 96 * 1024 * 1024

    @Sendable
    func bulk(_ req: Request, ctx: AppRequestContext) async throws -> BulkResponse {
        let tenantID = try ctx.requireTenantID()
        var mutableReq = req
        let buffer = try await mutableReq.collectBody(upTo: maxBodyBytes)
        let body: BulkRequest
        do {
            body = try JSONDecoder().decode(BulkRequest.self, from: Data(buffer: buffer))
        } catch {
            throw HTTPError(.badRequest, message: "invalid_body")
        }
        guard !body.space.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError(.badRequest, message: "space_required")
        }
        guard !body.files.isEmpty else {
            throw HTTPError(.badRequest, message: "no_files")
        }
        guard body.files.count <= maxFilesPerRequest else {
            throw HTTPError(.badRequest, message: "too_many_files_max_\(maxFilesPerRequest)")
        }
        let result = try await ingest.ingestBatch(tenantID: tenantID, spaceName: body.space, files: body.files)
        return BulkResponse(
            spaceID: result.spaceID.uuidString,
            spaceSlug: result.spaceSlug,
            imported: result.imported,
            skipped: result.skipped,
            failed: result.failed
        )
    }
}
