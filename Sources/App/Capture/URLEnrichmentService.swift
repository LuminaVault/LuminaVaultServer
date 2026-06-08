import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

struct URLEnrichmentService {
    let vaultPaths: VaultPathService
    let fluent: Fluent
    let logger: Logger
    /// HER-240 / spec ticket #3 — tier-2 post-processor. When configured,
    /// runs after the primary enricher to fill in `body` if metadata was
    /// shallow. Nil disables silently.
    let jinaEnricher: JinaEnricher?
    /// HER-54 (Slice 1) — capture-hook engine. When set, the tenant's enabled
    /// `.captureHook` plugins transform the enriched metadata at `.postEnrich`
    /// before markdown is rendered. Nil disables silently (failure-isolated).
    let captureHooks: CaptureHookDispatcher?
    /// HER-274 follow-up — when both are wired, the enriched link is embedded
    /// into the `memories` recall index (idempotent on `source_vault_file_id`)
    /// so chat grounding can surface saved links in later turns, not just at
    /// capture time. Nil on the chat pre-enricher instance (which only uses
    /// the side-effect-free `enrichURL`), set on the capture instance.
    let embeddings: (any EmbeddingService)?
    let memories: MemoryRepository?

    /// Register the enrichers in order of priority. Jina is NOT in this
    /// list — it runs as a tier-2 post-processor (`applyJinaIfShallow`)
    /// instead of as a primary winner-takes-all match.
    private let enrichers: [any URLEnricher] = [
        YouTubeEnricher(),
        XEnricher(),
        GenericOGEnricher(),
    ]

    init(
        vaultPaths: VaultPathService,
        fluent: Fluent,
        logger: Logger,
        jinaEnricher: JinaEnricher? = nil,
        captureHooks: CaptureHookDispatcher? = nil,
        embeddings: (any EmbeddingService)? = nil,
        memories: MemoryRepository? = nil,
    ) {
        self.vaultPaths = vaultPaths
        self.fluent = fluent
        self.logger = logger
        self.jinaEnricher = jinaEnricher
        self.captureHooks = captureHooks
        self.embeddings = embeddings
        self.memories = memories
    }

    /// HER-240 / spec ticket #4 — lightweight enrichment for chat
    /// pre-processor. Runs the same enricher chain as `enrichAndRewrite`
    /// but skips all DB / disk side effects. SSRF-guarded. Returns nil
    /// when the URL fails parsing, SSRF check, or every enricher throws.
    func enrichURL(_ urlString: String) async -> EnrichedMetadata? {
        guard let url = URL(string: urlString) else { return nil }
        guard URLEnricherGuard.isPublic(url) else {
            logger.warning("chat-enrichment rejected non-public url=\(urlString)")
            return nil
        }
        guard let enricher = enrichers.first(where: { $0.canHandle(url: url) }) else {
            return nil
        }
        do {
            return try await enricher.enrich(url: url)
        } catch {
            logger.warning("chat-enrichment failed url=\(urlString) error=\(error)")
            return nil
        }
    }

    func enrichAndRewrite(vaultFileID: UUID, urlString: String, tenantID: UUID) async {
        let db = fluent.db()
        do {
            guard let url = URL(string: urlString) else {
                throw HTTPError(.badRequest, message: "Invalid URL string")
            }

            guard URLEnricherGuard.isPublic(url) else {
                logger.warning("enrichment rejected non-public url tenant=\(tenantID) url=\(urlString)")
                throw HTTPError(.badRequest, message: "URL host is not enrichable")
            }

            // Find the appropriate enricher
            guard let enricher = enrichers.first(where: { $0.canHandle(url: url) }) else {
                throw HTTPError(.badRequest, message: "No enricher can handle this URL")
            }

            logger.info("enrichment started tenant=\(tenantID) file=\(vaultFileID) url=\(urlString)")
            let primary = try await enricher.enrich(url: url)
            var metadata = await applyJinaIfShallow(metadata: primary, url: url, tenantID: tenantID)

            // HER-54 (Slice 1) — let the tenant's installed `.captureHook`
            // plugins transform the enriched metadata before render. The
            // dispatcher is failure-isolated, so a bad hook can't break capture.
            if let captureHooks {
                let context = CaptureHookContext(
                    tenantID: tenantID,
                    url: urlString,
                    config: [:],
                    metadata: metadata,
                )
                metadata = await captureHooks.run(point: .postEnrich, context: context).metadata
            }

            // Format the new markdown
            var markdown = ""
            markdown += "---\n"
            if let title = metadata.title, !title.isEmpty {
                // Escape quotes in frontmatter
                markdown += "title: \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
            }
            markdown += "source: \"\(urlString)\"\n"
            if let author = metadata.author, !author.isEmpty {
                markdown += "author: \"\(author.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
            }
            if let imageURL = metadata.imageURL, !imageURL.isEmpty {
                markdown += "image: \"\(imageURL)\"\n"
            }
            // HER-54 — emitted by the `reading-time` capture hook when installed.
            if let readingTime = metadata.readingTimeMinutes {
                markdown += "reading_time: \(readingTime)\n"
            }
            markdown += "---\n\n"

            if let title = metadata.title, !title.isEmpty {
                markdown += "# \(title)\n\n"
            }

            if let description = metadata.description, !description.isEmpty {
                markdown += "## Description\n\(description)\n\n"
            }

            if let transcript = metadata.transcript, !transcript.isEmpty {
                markdown += "## Transcript\n\(transcript)\n\n"
            }

            if let body = metadata.body, !body.isEmpty {
                markdown += "## Content\n\(body)\n\n"
            }

            // Tenant-scoped lookup (S1a): never fetch a VaultFile by id alone —
            // bind it to the enrichment's tenant so a stray/replayed id can't
            // reach another tenant's row.
            guard let row = try await VaultFile.query(on: db, tenantID: tenantID)
                .filter(\.$id == vaultFileID)
                .first()
            else {
                throw HTTPError(.notFound, message: "VaultFile not found")
            }

            // Write to disk
            let rawRoot = vaultPaths.rawDirectory(for: tenantID)
            let target = try VaultController.resolveInside(rawRoot: rawRoot, relative: row.path)

            if let data = markdown.data(using: .utf8) {
                try data.write(to: target, options: .atomic)

                // Update DB row
                row.sizeBytes = Int64(data.count)
                row.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if row.metadata == nil {
                    row.metadata = VaultFileMetadata(enrichmentStatus: "done")
                } else {
                    row.metadata?.enrichmentStatus = "done"
                }
                try await row.save(on: db)
                logger.info("enrichment completed tenant=\(tenantID) file=\(vaultFileID)")

                // HER-274 follow-up — embed the enriched link into the recall
                // index so `memories.semanticSearch` (chat grounding) surfaces
                // it in future turns. Mirrors VaultIngestService's idempotent
                // upsert. Failure-isolated: the capture already succeeded.
                await indexMemory(
                    metadata: metadata,
                    vaultFileID: vaultFileID,
                    spaceID: row.spaceID,
                    tenantID: tenantID,
                )
            }
        } catch {
            logger.error("enrichment failed tenant=\(tenantID) file=\(vaultFileID): \(error)")
            // Mark as failed
            if let row = try? await VaultFile.query(on: db, tenantID: tenantID)
                .filter(\.$id == vaultFileID)
                .first()
            {
                if row.metadata == nil {
                    row.metadata = VaultFileMetadata(enrichmentStatus: "failed")
                } else {
                    row.metadata?.enrichmentStatus = "failed"
                }
                try? await row.save(on: db)
            }
        }
    }

    /// HER-274 follow-up — embed enriched link content into `memories` so it
    /// joins the semantic recall index (chat grounding). Mirrors
    /// `VaultIngestService`'s idempotent upsert: update the memory already
    /// bound to this vault file, else create one. No-op unless both
    /// `embeddings` and `memories` are wired (chat pre-enricher leaves them
    /// nil). Never throws — capture + enrichment already committed.
    private func indexMemory(
        metadata: EnrichedMetadata,
        vaultFileID: UUID,
        spaceID: UUID?,
        tenantID: UUID,
    ) async {
        guard let embeddings, let memories else { return }
        let text = [metadata.title, metadata.description, metadata.transcript, metadata.body]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else {
            logger.info("link memory skipped (empty enriched content) tenant=\(tenantID) file=\(vaultFileID)")
            return
        }
        do {
            let embedding = try await embeddings.embed(text, tenantID: tenantID)
            if let existing = try await memories.idBySourceVaultFileID(tenantID: tenantID, sourceVaultFileID: vaultFileID) {
                _ = try await memories.updateContent(tenantID: tenantID, id: existing, content: text, embedding: embedding)
                logger.info("link memory updated tenant=\(tenantID) file=\(vaultFileID) chars=\(text.count)")
            } else {
                _ = try await memories.create(
                    tenantID: tenantID,
                    content: text,
                    embedding: embedding,
                    tags: ["link"],
                    sourceVaultFileID: vaultFileID,
                    spaceID: spaceID,
                    reviewState: "auto",
                )
                logger.info("link memory created tenant=\(tenantID) file=\(vaultFileID) chars=\(text.count)")
            }
        } catch {
            logger.warning("link memory indexing failed tenant=\(tenantID) file=\(vaultFileID) error=\(error)")
        }
    }

    /// HER-240 / spec ticket #3 — tier-2 post-processor. Runs `JinaEnricher`
    /// when the primary enricher returned a thin description (< 500 chars,
    /// transcript also < 500 chars) and no body already. Merges jina's body
    /// into the metadata; on jina failure (rate-limit, network, etc.)
    /// returns the primary metadata unchanged so the capture still lands.
    private func applyJinaIfShallow(metadata: EnrichedMetadata, url: URL, tenantID: UUID) async -> EnrichedMetadata {
        guard let jinaEnricher else { return metadata }
        if metadata.body?.isEmpty == false { return metadata }
        let descLen = metadata.description?.count ?? 0
        let transcriptLen = metadata.transcript?.count ?? 0
        if descLen >= 500 || transcriptLen >= 500 { return metadata }

        do {
            let jina = try await jinaEnricher.enrich(url: url)
            var merged = metadata
            merged.body = jina.body
            logger.info("jina tier-2 enrichment merged tenant=\(tenantID) body_chars=\(jina.body?.count ?? 0)")
            return merged
        } catch {
            logger.warning("jina tier-2 enrichment failed; using primary tenant=\(tenantID) error=\(error)")
            return metadata
        }
    }
}
