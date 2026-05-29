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

    /// Register the enrichers in order of priority. Jina is NOT in this
    /// list — it runs as a tier-2 post-processor (`applyJinaIfShallow`)
    /// instead of as a primary winner-takes-all match.
    private let enrichers: [any URLEnricher] = [
        YouTubeEnricher(),
        XEnricher(),
        GenericOGEnricher(),
    ]

    init(vaultPaths: VaultPathService, fluent: Fluent, logger: Logger, jinaEnricher: JinaEnricher? = nil) {
        self.vaultPaths = vaultPaths
        self.fluent = fluent
        self.logger = logger
        self.jinaEnricher = jinaEnricher
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
            let metadata = await applyJinaIfShallow(metadata: primary, url: url, tenantID: tenantID)

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

            guard let row = try await VaultFile.find(vaultFileID, on: db) else {
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
            }
        } catch {
            logger.error("enrichment failed tenant=\(tenantID) file=\(vaultFileID): \(error)")
            // Mark as failed
            if let row = try? await VaultFile.find(vaultFileID, on: db) {
                if row.metadata == nil {
                    row.metadata = VaultFileMetadata(enrichmentStatus: "failed")
                } else {
                    row.metadata?.enrichmentStatus = "failed"
                }
                try? await row.save(on: db)
            }
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
