import Crypto
import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-274 — extracted from `CaptureController.captureSafari` so the
/// same persistence pipeline (vault file write → DB row → enrichment
/// kickoff → SkillEvent.vaultFileCreated → achievement bump) can be
/// reused from non-HTTP callers like the chat auto-save-link post-
/// processor.
///
/// `CaptureController` is now a thin HTTP shim over this service;
/// `ConversationController.streamReply` invokes it directly per URL
/// detected by `URLExtractionService` once the assistant turn is
/// persisted.
struct LinkCaptureService {
    let vaultPaths: VaultPathService
    let fluent: Fluent
    let eventBus: EventBus?
    let achievements: AchievementsService?
    let enrichmentService: URLEnrichmentService
    let logger: Logger

    enum CaptureError: Error {
        case invalidURL
        case nonPublicHost
    }

    struct CapturedLink {
        let fileID: UUID
        let relativePath: String
    }

    /// Persist a single URL to the tenant's vault with the same shape
    /// the Safari share extension uses. Idempotent at the filesystem
    /// layer (filename is `captures/<UTC-timestamp>-<host>.md`); two
    /// calls within the same second for the same URL will collide on
    /// disk — callers are responsible for inbound dedup. Inline by
    /// design: keeps the call site (chat stream done branch, share
    /// extension HTTP handler) able to surface the resulting path
    /// synchronously.
    func captureLink(
        tenantID: UUID,
        url urlString: String,
        note: String?,
    ) async throws -> CapturedLink {
        guard let url = URL(string: urlString) else {
            throw CaptureError.invalidURL
        }
        guard URLEnricherGuard.isPublic(url) else {
            throw CaptureError.nonPublicHost
        }

        var markdown = """
        ---
        source: "\(urlString)"
        ---

        # [Pending Enrichment]
        URL: \(urlString)

        """

        if let note, !note.isEmpty {
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

        logger.info("link captured tenant=\(tenantID) url=\(urlString) path=\(relativePath)")

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

        Task.detached { [enrichmentService] in
            await enrichmentService.enrichAndRewrite(vaultFileID: fileID, urlString: urlString, tenantID: tenantID)
        }

        return CapturedLink(fileID: fileID, relativePath: relativePath)
    }
}
