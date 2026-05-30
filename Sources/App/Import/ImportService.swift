import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// "Feed Your Brain" P1 — stages a batch of links into the reserved `imported`
/// inbox Space as `vault_files` (reusing the single-link capture pipeline) and
/// records an `ImportSession` + `ImportItem`s so the client can track progress
/// and later run Smart Import categorization + filing + compile.
///
/// Enrichment currently rides `LinkCaptureService`'s per-link async kickoff;
/// the plan replaces that with a concurrency-capped `ImportWorker` for large
/// batches.
struct ImportService {
    let fluent: Fluent
    let linkCapture: LinkCaptureService
    let spaces: SpacesService
    let logger: Logger

    static let maxBatch = 500
    static let importedSlug = "imported"

    struct StageResult {
        let sessionID: UUID
        let total: Int
        let staged: Int
        let skipped: Int
    }

    func importLinks(tenantID: UUID, sourceType: String, urls: [String]) async throws -> StageResult {
        let db = fluent.db()
        let importedSpaceID = try await ensureImportedSpace(tenantID: tenantID)

        let session = ImportSession(
            tenantID: tenantID,
            sourceType: sourceType,
            status: ImportStatus.staging,
            totalItems: urls.count,
        )
        try await session.save(on: db)
        let sessionID = try session.requireID()

        // Dedup against URLs this tenant has already imported (any session).
        let priorItems = try await ImportItem.query(on: db, tenantID: tenantID).all()
        var seen = Set(priorItems.compactMap(\.url))

        var staged = 0
        var skipped = 0
        for raw in urls {
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }
            if seen.contains(url) {
                skipped += 1
                continue
            }
            seen.insert(url)
            do {
                let captured = try await linkCapture.captureLink(
                    tenantID: tenantID,
                    url: url,
                    note: nil,
                    spaceID: importedSpaceID,
                )
                let item = ImportItem(
                    tenantID: tenantID,
                    sessionID: sessionID,
                    vaultFileID: captured.fileID,
                    url: url,
                    status: ImportItemStatus.staged,
                )
                try await item.save(on: db)
                staged += 1
            } catch LinkCaptureService.CaptureError.invalidURL,
                    LinkCaptureService.CaptureError.nonPublicHost {
                let item = ImportItem(
                    tenantID: tenantID,
                    sessionID: sessionID,
                    url: url,
                    status: ImportItemStatus.skipped,
                )
                try await item.save(on: db)
                skipped += 1
            }
        }

        session.stagedItems = staged
        session.status = ImportStatus.enriching
        try await session.save(on: db)
        logger.info("import staged tenant=\(tenantID) session=\(sessionID) staged=\(staged) skipped=\(skipped)")
        return StageResult(sessionID: sessionID, total: urls.count, staged: staged, skipped: skipped)
    }

    func status(tenantID: UUID, sessionID: UUID) async throws -> (ImportSession, [ImportItem]) {
        guard let session = try await ImportSession.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == sessionID)
            .first()
        else {
            throw HTTPError(.notFound, message: "import session not found")
        }
        let items = try await ImportItem.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$sessionID == sessionID)
            .sort(\.$createdAt, .ascending)
            .all()
        return (session, items)
    }

    /// Find-or-create the reserved `imported` inbox Space.
    private func ensureImportedSpace(tenantID: UUID) async throws -> UUID {
        if let existing = try await Space.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$slug == Self.importedSlug)
            .first()
        {
            return try existing.requireID()
        }
        let space = try await spaces.create(
            tenantID: tenantID,
            name: "Imported",
            slugRaw: Self.importedSlug,
            description: "Inbox for imported items awaiting Smart Import.",
            color: nil,
            icon: "tray",
            category: nil,
        )
        return try space.requireID()
    }
}
