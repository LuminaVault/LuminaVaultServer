import Foundation
import Logging

/// Turns a document's text into searchable, citable chunks.
///
/// One place owns the chunk → embed → store sequence, so the three ingest paths
/// (`VaultIngestService`, `MultimodalIngestionService`, and the backfill job)
/// cannot drift into three subtly different chunking behaviors.
///
/// Chunk indexing is deliberately **non-fatal** at its call sites. The
/// document-level `memories` row and its whole-document embedding are written
/// first and independently, and `HybridMemorySearch` unions the document arm
/// with the chunk arm — so a document whose chunking failed is still findable,
/// just without line-level citations. Ingestion never fails because an
/// embedding provider hiccuped on chunk 7 of 40.
struct DocumentChunkIndexer: Sendable {
    let chunks: MemoryChunkRepository
    let embeddings: any EmbeddingService
    let logger: Logger

    /// Chunk `content`, embed each chunk, and replace the memory's chunk set.
    ///
    /// - Parameter sourcePath: vault-relative path used in citations. Nil for
    ///   memories with no backing file; those chunks are still searchable but
    ///   cite only a heading and line range.
    /// - Returns: the number of chunks written.
    @discardableResult
    func index(
        tenantID: UUID,
        memoryID: UUID,
        vaultFileID: UUID?,
        spaceID: UUID?,
        sourcePath: String?,
        content: String
    ) async throws -> Int {
        let documentChunks = MarkdownChunker.chunk(content)
        guard !documentChunks.isEmpty else {
            // Whitespace-only or empty body: clear any stale chunks so a
            // document emptied by an edit stops returning its old text.
            try await chunks.deleteChunks(tenantID: tenantID, memoryID: memoryID)
            return 0
        }

        let documentID = ChunkIDs.documentID(
            tenantID: tenantID,
            path: sourcePath ?? memoryID.uuidString
        )
        let vectors = try await embeddings.embedBatch(
            documentChunks.map(\.text),
            tenantID: tenantID
        )

        try await chunks.replaceChunks(
            tenantID: tenantID,
            memoryID: memoryID,
            documentID: documentID,
            vaultFileID: vaultFileID,
            spaceID: spaceID,
            sourcePath: sourcePath,
            chunks: documentChunks,
            embeddings: vectors
        )
        return documentChunks.count
    }

    /// `index` with failures swallowed and logged — the shape every ingest path
    /// wants, so no call site has to remember the non-fatal policy.
    func indexBestEffort(
        tenantID: UUID,
        memoryID: UUID,
        vaultFileID: UUID?,
        spaceID: UUID?,
        sourcePath: String?,
        content: String
    ) async {
        do {
            let count = try await index(
                tenantID: tenantID,
                memoryID: memoryID,
                vaultFileID: vaultFileID,
                spaceID: spaceID,
                sourcePath: sourcePath,
                content: content
            )
            logger.debug("chunk.index tenant=\(tenantID) memory=\(memoryID) chunks=\(count)")
        } catch {
            logger.error(
                "chunk.index.failed tenant=\(tenantID) memory=\(memoryID) path=\(sourcePath ?? "-"): \(error)"
            )
        }
    }
}
