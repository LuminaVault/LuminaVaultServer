import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// Imports external markdown (e.g. a user's Hermes/Obsidian vault) into
/// LuminaVault's own store so chat grounding, recall, and the Brain graph use
/// it. Each file → on-disk blob + `VaultFile` row + embedded `Memory`
/// (space-scoped). Mirrors the note-capture path in `VaultController.upload`
/// (`?note=true`); dedup is path+sha256 keyed so re-importing the same vault
/// skips unchanged files. `[[wikilinks]]` ride in the markdown body and are
/// rendered by `MemoryGraphService`.
struct VaultIngestService {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let spaces: SpacesService
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let logger: Logger

    struct FileInput: Decodable, Sendable {
        let path: String
        let content: String
    }

    struct Result: Sendable {
        let spaceID: UUID
        let spaceSlug: String
        var imported: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
    }

    /// Ingest a batch of markdown files into one Space (created if needed).
    func ingestBatch(tenantID: UUID, spaceName: String, files: [FileInput]) async throws -> Result {
        let space = try await ensureSpace(tenantID: tenantID, name: spaceName)
        let spaceID = try space.requireID()
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        var result = Result(spaceID: spaceID, spaceSlug: space.slug)
        for file in files {
            do {
                let ingested = try await ingestOne(tenantID: tenantID, spaceID: spaceID, slug: space.slug, input: file)
                if ingested { result.imported += 1 } else { result.skipped += 1 }
            } catch {
                result.failed += 1
                logger.error("vault ingest failed tenant=\(tenantID) path=\(file.path): \(error)")
            }
        }
        logger.info("vault ingest tenant=\(tenantID) space=\(space.slug) imported=\(result.imported) skipped=\(result.skipped) failed=\(result.failed)")
        return result
    }

    // MARK: - Internals

    private func ensureSpace(tenantID: UUID, name: String) async throws -> Space {
        let slug = ImportService.slugify(name)
        if let existing = try await Space.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$slug == slug).first()
        {
            return existing
        }
        return try await spaces.create(
            tenantID: tenantID, name: name, slugRaw: slug,
            description: "Imported from your Hermes vault.",
            color: nil, icon: "tray.and.arrow.down", category: nil,
        )
    }

    /// Returns true when the file was (re)ingested, false when skipped
    /// (empty, or unchanged since a prior import).
    private func ingestOne(tenantID: UUID, spaceID: UUID, slug: String, input: FileInput) async throws -> Bool {
        let content = input.content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        // Obsidian filenames carry spaces / em-dashes / emoji / parens, which the
        // strict vault sanitizer rejects. Slugify each path segment ourselves
        // (preserving subfolder structure to avoid basename collisions) and keep
        // the human title for display in metadata.
        let safeRelative = Self.safePath(slug: slug, rawPath: input.path)
        let data = Data(content.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let db = fluent.db()
        let existing = try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$path == safeRelative).first()
        if let existing, existing.sha256 == digest { return false } // unchanged

        // Write the on-disk blob (the row is the index, the file is the payload).
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = try VaultController.resolveInside(rawRoot: rawRoot, relative: safeRelative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try data.write(to: target, options: .atomic)

        let humanName = (input.path as NSString).lastPathComponent
        let metadata = VaultFileMetadata(title: Self.title(from: content, fallback: humanName))
        let savedID: UUID
        if let existing {
            existing.spaceID = spaceID
            existing.sizeBytes = Int64(data.count)
            existing.sha256 = digest
            existing.processedAt = Date()
            existing.metadata = metadata
            try await existing.save(on: db)
            savedID = try existing.requireID()
        } else {
            let row = VaultFile(
                tenantID: tenantID, spaceID: spaceID, path: safeRelative,
                contentType: "text/markdown", sizeBytes: Int64(data.count),
                sha256: digest, processedAt: Date(), metadata: metadata,
            )
            try await row.save(on: db)
            savedID = try row.requireID()
        }

        // Embed + create/update the recall memory (grounding + graph source).
        let embedding = try await embeddings.embed(content, tenantID: tenantID)
        if let memID = try await memories.idBySourceVaultFileID(tenantID: tenantID, sourceVaultFileID: savedID) {
            _ = try await memories.updateContent(tenantID: tenantID, id: memID, content: content, embedding: embedding)
        } else {
            _ = try await memories.create(
                tenantID: tenantID, content: content, embedding: embedding,
                tags: nil, sourceVaultFileID: savedID, spaceID: spaceID, reviewState: "auto",
            )
        }
        return true
    }

    /// First markdown H1, else the filename (sans extension).
    private static func title(from content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return (fallback as NSString).deletingPathExtension
    }

    /// Build a filesystem-safe relative path under the space, preserving subfolder
    /// structure. Each segment is slugified (spaces/em-dash/emoji/parens → `-`);
    /// the file always ends `.md`. `..`/`.` segments dropped (traversal-safe; the
    /// caller also runs it through `resolveInside`).
    static func safePath(slug: String, rawPath: String) -> String {
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." && $0 != ".." }
        var segs: [String] = []
        for (i, part) in parts.enumerated() {
            if i == parts.count - 1 {
                segs.append(slugifySegment((part as NSString).deletingPathExtension) + ".md")
            } else {
                segs.append(slugifySegment(part))
            }
        }
        if segs.isEmpty { segs = ["note.md"] }
        return ([slug] + segs).joined(separator: "/")
    }

    private static func slugifySegment(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "." || ch == "_" {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "x" : String(out.prefix(80))
    }
}
