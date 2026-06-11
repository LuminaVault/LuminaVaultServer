import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// "Feed Your Brain" — stages a link batch into the reserved `imported` inbox
/// Space (reusing the single-link capture pipeline), then on approval files each
/// item into its chosen Space and runs a scoped memory-compile.
struct ImportService {
    let fluent: Fluent
    let linkCapture: LinkCaptureService
    let spaces: SpacesService
    let vaultPaths: VaultPathService
    let memoryCompile: MemoryCompileService
    let urlEnrich: URLEnrichmentService
    let logger: Logger

    /// Max concurrent link enrichments during approve (avoid stampeding the
    /// network / upstream OG+Jina services on a large import).
    static let enrichConcurrency = 4
    /// Cap on links enriched INLINE during approve so the request can't hang on
    /// a huge import (e.g. 500 bookmarks × network fetch). Links beyond the cap
    /// are still enriched by their staging-time task and picked up by a later
    /// Sync & Learn — they just don't all land as memories in this one call.
    static let maxInlineEnrich = 50

    static let maxBatch = 500
    static let importedSlug = "imported"

    /// Extract http(s) URLs from a Netscape bookmarks HTML export (Safari /
    /// Chrome / Firefox "Export Bookmarks"). Order-preserving dedupe.
    static func parseBookmarksHTML(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(?i)href\s*=\s*["']([^"']+)["']"#) else { return [] }
        let ns = html as NSString
        var urls: [String] = []
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let u = ns.substring(with: match.range(at: 1))
            if u.hasPrefix("http://") || u.hasPrefix("https://") { urls.append(u) }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    struct StageResult {
        let sessionID: UUID
        let total: Int
        let staged: Int
        let skipped: Int
    }

    // MARK: - Stage

    func importLinks(tenantID: UUID, sourceType: String, urls: [String]) async throws -> StageResult {
        let db = fluent.db()
        let importedSpaceID = try await ensureImportedSpace(tenantID: tenantID)

        let session = ImportSession(
            tenantID: tenantID,
            sourceType: sourceType,
            status: ImportStatus.staging,
            totalItems: urls.count
        )
        try await session.save(on: db)
        let sessionID = try session.requireID()

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
                    tenantID: tenantID, url: url, note: nil, spaceID: importedSpaceID
                )
                let item = ImportItem(
                    tenantID: tenantID, sessionID: sessionID, vaultFileID: captured.fileID,
                    url: url, status: ImportItemStatus.staged
                )
                try await item.save(on: db)
                staged += 1
            } catch LinkCaptureService.CaptureError.invalidURL,
                LinkCaptureService.CaptureError.nonPublicHost
            {
                let item = ImportItem(
                    tenantID: tenantID, sessionID: sessionID, url: url, status: ImportItemStatus.skipped
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

    /// Open an import session over already-uploaded vault files (photos,
    /// documents, EventKit-rendered markdown). The client first uploads each
    /// asset via `POST /v1/vault/files?space_id=<imported>`, then registers the
    /// returned ids here so they flow through categorize → approve like links.
    func importFiles(tenantID: UUID, sourceType: String, vaultFileIDs: [UUID]) async throws -> StageResult {
        let db = fluent.db()
        let session = ImportSession(
            tenantID: tenantID, sourceType: sourceType,
            status: ImportStatus.staging, totalItems: vaultFileIDs.count
        )
        try await session.save(on: db)
        let sessionID = try session.requireID()

        var staged = 0
        for vfID in vaultFileIDs {
            guard let vf = try await VaultFile.query(on: db, tenantID: tenantID)
                .filter(\.$id == vfID).first()
            else { continue }
            let item = ImportItem(
                tenantID: tenantID, sessionID: sessionID, vaultFileID: vfID,
                title: (vf.path as NSString).lastPathComponent, status: ImportItemStatus.staged
            )
            try await item.save(on: db)
            staged += 1
        }

        session.stagedItems = staged
        session.status = ImportStatus.enriching
        try await session.save(on: db)
        logger.info("import files staged tenant=\(tenantID) session=\(sessionID) staged=\(staged)")
        return StageResult(sessionID: sessionID, total: vaultFileIDs.count, staged: staged, skipped: vaultFileIDs.count - staged)
    }

    // MARK: - Approve (file + compile)

    struct ApproveResult {
        let filed: Int
        let memories: Int
    }

    /// Files each categorized item into its chosen Space (creating proposed new
    /// Spaces), moving the vault file into `raw/<slug>/`, then runs a scoped
    /// compile over the session's files. `overrides` (itemId → slug | new:Name |
    /// imported) lets the user adjust the proposal before approving.
    func approve(tenantID: UUID, sessionID: UUID, overrides: [String: String]) async throws -> ApproveResult {
        let db = fluent.db()
        guard let session = try await ImportSession.query(on: db, tenantID: tenantID)
            .filter(\.$id == sessionID).first()
        else { throw HTTPError(.notFound, message: "import session not found") }

        session.status = ImportStatus.filing
        try await session.save(on: db)

        let items = try await ImportItem.query(on: db, tenantID: tenantID)
            .filter(\.$sessionID == sessionID)
            .filter(\.$status != ImportItemStatus.skipped)
            .all()

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let fm = FileManager.default
        var slugCache: [String: UUID] = [:]
        var compiledFileIDs: [UUID] = []
        var filed = 0

        for item in items {
            guard let vfID = item.vaultFileID,
                  let vf = try await VaultFile.query(on: db, tenantID: tenantID).filter(\.$id == vfID).first()
            else { continue }
            let itemID = try item.requireID().uuidString
            let target = overrides[itemID] ?? item.proposedSpace ?? Self.importedSlug

            let destSlug = try await resolveDestSlug(tenantID: tenantID, target: target, slugCache: &slugCache)
            let spaceID = try await spaceID(tenantID: tenantID, slug: destSlug, slugCache: &slugCache)

            let base = (vf.path as NSString).lastPathComponent
            let newRel = "\(destSlug)/\(base)"
            if vf.path != newRel {
                let src = rawRoot.appendingPathComponent(vf.path)
                let dst = rawRoot.appendingPathComponent(newRel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: src.path) {
                    if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                    try? fm.moveItem(at: src, to: dst)
                }
                vf.path = newRel
            }
            vf.spaceID = spaceID
            try await vf.save(on: db)
            compiledFileIDs.append(vfID)
            item.status = ImportItemStatus.filed
            try await item.save(on: db)
            filed += 1
        }

        // Enrich link items (bounded concurrency) so the scoped compile sees
        // real article content, not the "# [Pending Enrichment]" skeleton — so
        // an import yields memories in-flow instead of on the next Sync & Learn.
        await enrichLinks(tenantID: tenantID, items: items)

        session.status = ImportStatus.compiling
        try await session.save(on: db)

        var memories = 0
        if !compiledFileIDs.isEmpty {
            let rows = try await VaultFile.query(on: db, tenantID: tenantID)
                .filter(\.$id ~~ compiledFileIDs)
                .filter(\.$processedAt == nil)
                .all()
            if !rows.isEmpty {
                let result = try await memoryCompile.compileExistingVaultFiles(
                    tenantID: tenantID, sessionKey: tenantID.uuidString,
                    rows: rows, hint: nil, runId: UUID()
                )
                memories = result.memories.count
            }
        }

        session.status = ImportStatus.done
        try await session.save(on: db)
        logger.info("import approved tenant=\(tenantID) session=\(sessionID) filed=\(filed) memories=\(memories)")
        return ApproveResult(filed: filed, memories: memories)
    }

    /// Bounded-concurrency enrichment over the session's link items whose vault
    /// file is still enrichment-pending. Best-effort (enrichAndRewrite never
    /// throws). Re-reads the row inside, so it works after the filing move.
    private func enrichLinks(tenantID: UUID, items: [ImportItem]) async {
        let db = fluent.db()
        var jobs: [(UUID, String)] = []
        for item in items {
            guard let url = item.url, let vfID = item.vaultFileID else { continue }
            if let vf = try? await VaultFile.query(on: db, tenantID: tenantID).filter(\.$id == vfID).first(),
               vf.metadata?.enrichmentStatus == "pending"
            {
                jobs.append((vfID, url))
            }
        }
        if jobs.count > Self.maxInlineEnrich {
            logger.info("import enrich capped: \(jobs.count) links, enriching \(Self.maxInlineEnrich) inline; rest land on next compile")
            jobs = Array(jobs.prefix(Self.maxInlineEnrich))
        }
        guard !jobs.isEmpty else { return }
        let urlEnrich = urlEnrich
        await withTaskGroup(of: Void.self) { group in
            var i = 0
            func addNext() {
                guard i < jobs.count else { return }
                let (vfID, url) = jobs[i]; i += 1
                group.addTask { await urlEnrich.enrichAndRewrite(vaultFileID: vfID, urlString: url, tenantID: tenantID) }
            }
            for _ in 0 ..< Self.enrichConcurrency {
                addNext()
            }
            for await _ in group {
                addNext()
            }
        }
    }

    func status(tenantID: UUID, sessionID: UUID) async throws -> (ImportSession, [ImportItem]) {
        guard let session = try await ImportSession.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == sessionID).first()
        else { throw HTTPError(.notFound, message: "import session not found") }
        let items = try await ImportItem.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$sessionID == sessionID)
            .sort(\.$createdAt, .ascending)
            .all()
        return (session, items)
    }

    // MARK: - Space helpers

    /// Resolves an approval target (`slug` | `new:Name` | `imported`) to a real,
    /// existing Space slug — creating a proposed new Space when needed.
    private func resolveDestSlug(tenantID: UUID, target: String, slugCache _: inout [String: UUID]) async throws -> String {
        if target.isEmpty || target == Self.importedSlug { return Self.importedSlug }
        if target.hasPrefix("new:") {
            let name = String(target.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let slug = Self.slugify(name)
            if try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$slug == slug).first() == nil {
                _ = try? await spaces.create(
                    tenantID: tenantID, name: name.isEmpty ? slug : name, slugRaw: slug,
                    description: nil, color: nil, icon: nil, category: nil
                )
            }
            return slug
        }
        // existing slug — verify it exists; fall back to inbox if not.
        if try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$slug == target).first() != nil {
            return target
        }
        return Self.importedSlug
    }

    private func spaceID(tenantID: UUID, slug: String, slugCache: inout [String: UUID]) async throws -> UUID {
        if let cached = slugCache[slug] { return cached }
        if let space = try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$slug == slug).first() {
            let id = try space.requireID()
            slugCache[slug] = id
            return id
        }
        let importedID = try await ensureImportedSpace(tenantID: tenantID)
        slugCache[slug] = importedID
        return importedID
    }

    private func ensureImportedSpace(tenantID: UUID) async throws -> UUID {
        if let existing = try await Space.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$slug == Self.importedSlug).first()
        {
            return try existing.requireID()
        }
        let space = try await spaces.create(
            tenantID: tenantID, name: "Imported", slugRaw: Self.importedSlug,
            description: "Inbox for imported items awaiting Smart Import.",
            color: nil, icon: "tray", category: nil
        )
        return try space.requireID()
    }

    /// Filesystem/Space-safe slug from a free-text name (matches SpaceSlugPolicy:
    /// `^[a-z0-9][a-z0-9-]{1,30}$`).
    static func slugify(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(31))
        if out.count < 2 { out = "imported" }
        return out
    }
}
