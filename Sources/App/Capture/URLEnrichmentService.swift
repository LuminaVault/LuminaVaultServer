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

    /// Register the enrichers in order of priority
    private let enrichers: [any URLEnricher] = [
        YouTubeEnricher(),
        XEnricher(),
        GenericOGEnricher(),
    ]

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
            let metadata = try await enricher.enrich(url: url)

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
}
