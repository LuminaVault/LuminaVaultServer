import Foundation
import Logging

actor VaultNoteMemoryUpsertQueue {
    private struct Job {
        let tenantID: UUID
        let sourceVaultFileID: UUID
        let fileURL: URL
        let spaceID: UUID?
        let tags: [String]?
        let path: String
    }

    private let memories: MemoryRepository
    private let embeddings: any EmbeddingService
    private let logger: Logger
    private let maxPending: Int
    private var pending: [Job] = []
    private var worker: Task<Void, Never>?

    init(
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        logger: Logger,
        maxPending: Int = 128
    ) {
        self.memories = memories
        self.embeddings = embeddings
        self.logger = logger
        self.maxPending = maxPending
    }

    func enqueue(
        tenantID: UUID,
        sourceVaultFileID: UUID,
        fileURL: URL,
        spaceID: UUID?,
        tags: [String]?,
        path: String
    ) {
        guard pending.count < maxPending else {
            logger.warning("note memory upsert queue full tenant=\(tenantID) path=\(path)")
            return
        }
        pending.append(Job(
            tenantID: tenantID,
            sourceVaultFileID: sourceVaultFileID,
            fileURL: fileURL,
            spaceID: spaceID,
            tags: tags,
            path: path
        ))
        if worker == nil {
            worker = Task { await self.process() }
        }
    }

    func drain() async {
        while let worker {
            await worker.value
        }
    }

    private func process() async {
        while true {
            guard let job = nextJob() else {
                worker = nil
                return
            }
            await process(job)
        }
    }

    private func nextJob() -> Job? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func process(_ job: Job) async {
        do {
            let data = try Data(contentsOf: job.fileURL)
            guard let content = String(data: data, encoding: .utf8), !content.isEmpty else { return }
            let embedding = try await embeddings.embed(content, tenantID: job.tenantID)
            if let existingMemID = try await memories.idBySourceVaultFileID(
                tenantID: job.tenantID,
                sourceVaultFileID: job.sourceVaultFileID
            ) {
                _ = try await memories.updateContent(
                    tenantID: job.tenantID,
                    id: existingMemID,
                    content: content,
                    embedding: embedding
                )
            } else {
                _ = try await memories.create(
                    tenantID: job.tenantID,
                    content: content,
                    embedding: embedding,
                    tags: job.tags,
                    sourceVaultFileID: job.sourceVaultFileID,
                    spaceID: job.spaceID,
                    reviewState: "auto"
                )
            }
        } catch {
            logger.error("note memory upsert failed tenant=\(job.tenantID) path=\(job.path): \(error)")
        }
    }
}
