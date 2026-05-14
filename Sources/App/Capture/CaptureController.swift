import Crypto
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging

struct CaptureSafariRequest: Codable {
    let url: String
    let note: String?
}

struct CaptureSafariResponse: Codable, ResponseEncodable {
    let id: UUID
    let path: String
    let status: String
}

struct CaptureController {
    let vaultPaths: VaultPathService
    let fluent: Fluent
    let eventBus: EventBus?
    let achievements: AchievementsService?
    let enrichmentService: URLEnrichmentService
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/safari", use: captureSafari)
    }

    @Sendable
    func captureSafari(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let body = try await request.decode(as: CaptureSafariRequest.self, context: ctx)
        guard let url = URL(string: body.url) else {
            throw HTTPError(.badRequest, message: "Invalid URL")
        }
        guard URLEnricherGuard.isPublic(url) else {
            throw HTTPError(.badRequest, message: "URL host is not enrichable")
        }

        // Construct basic markdown with pending status
        var markdown = """
        ---
        source: "\(body.url)"
        ---

        # [Pending Enrichment]
        URL: \(body.url)

        """

        if let note = body.note, !note.isEmpty {
            markdown += "\n## Note\n\(note)\n"
        }

        let data = markdown.data(using: .utf8) ?? Data()
        let sizeBytes = Int64(data.count)
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let cleanHost = (url.host ?? "link").replacingOccurrences(of: ".", with: "-")
        let relativePath = "captures/\(timestamp)-\(cleanHost).md"

        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = try VaultController.resolveInside(rawRoot: rawRoot, relative: relativePath)

        let fm = FileManager.default
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try data.write(to: target, options: .atomic)

        // Save to DB
        let db = fluent.db()
        let row = VaultFile(
            tenantID: tenantID,
            path: relativePath,
            contentType: "text/markdown",
            sizeBytes: sizeBytes,
            sha256: sha256,
            metadata: VaultFileMetadata(enrichmentStatus: "pending"),
        )
        try await row.save(on: db)
        let fileID = try row.requireID()

        logger.info("safari capture accepted tenant=\(tenantID) url=\(body.url) path=\(relativePath)")

        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .vaultUploaded) }
        }

        if let eventBus {
            let event = SkillEvent(
                type: .vaultFileCreated,
                tenantID: tenantID,
                payload: [
                    SkillEvent.PayloadKey.vaultFileID: fileID.uuidString,
                    SkillEvent.PayloadKey.vaultPath: relativePath,
                ],
            )
            eventBus.publish(event)
        }

        // Enqueue enrichment task
        Task.detached {
            await enrichmentService.enrichAndRewrite(vaultFileID: fileID, urlString: body.url, tenantID: tenantID)
        }

        let responseBody = CaptureSafariResponse(id: fileID, path: relativePath, status: "accepted")
        var res = try await responseBody.response(from: request, context: ctx)
        res.status = .accepted
        return res
    }
}
