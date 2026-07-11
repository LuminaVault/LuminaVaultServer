import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

struct HermesIngestionResult: Sendable {
    let title: String
    let markdown: String
    let summary: String
    let tags: [String]
    let credibility: IngestionCredibilityRecord
}

actor HermesMultimodalProcessor {
    let transport: any HermesChatTransport
    let model: String

    init(transport: any HermesChatTransport, model: String) {
        self.transport = transport
        self.model = model
    }

    func process(tenantID: UUID, source: String, contentType: String) async throws -> HermesIngestionResult {
        let prompt = """
        Analyze the source below using your available vision, document, audio, video, and web tools.
        The source is already in the user's LuminaVault and must remain the source of truth.
        Return JSON only with keys: title, markdown, summary, tags, credibility.
        credibility has score (0...100 or null for personal media), confidence (0...1), signals, rationale, version.
        Include OCR, transcript, page/time references, and important facts in markdown when applicable.
        Source: \(source)
        Content-Type: \(contentType)
        """
        let request = ChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            responseFormat: ["type": "json_object"],
            stream: false
        )
        let payload = try JSONEncoder().encode(request)
        let raw = try await transport.chatCompletions(payload: payload, sessionKey: tenantID.uuidString, sessionID: nil)
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: raw)
        guard let content = envelope.choices.first?.message.content,
              let data = Self.jsonData(from: content)
        else { throw HTTPError(.badGateway, message: "Hermes returned no ingestion result") }
        let result = try JSONDecoder().decode(ResultPayload.self, from: data)
        return HermesIngestionResult(
            title: result.title,
            markdown: result.markdown,
            summary: result.summary,
            tags: result.tags,
            credibility: IngestionCredibilityRecord(
                score: result.credibility.score.map { min(100, max(0, $0)) },
                confidence: min(1, max(0, result.credibility.confidence)),
                signals: result.credibility.signals,
                rationale: result.credibility.rationale,
                version: result.credibility.version
            )
        )
    }

    private static func jsonData(from value: String) -> Data? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start ... end]).data(using: .utf8)
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let responseFormat: [String: String]
        let stream: Bool
        enum CodingKeys: String, CodingKey { case model, messages, stream; case responseFormat = "response_format" }
    }

    private struct Message: Codable { let role: String; let content: String }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: Message }
        let choices: [Choice]
    }

    private struct ResultPayload: Decodable {
        struct Credibility: Decodable {
            let score: Int?
            let confidence: Double
            let signals: [String]
            let rationale: String
            let version: String
        }

        let title: String
        let markdown: String
        let summary: String
        let tags: [String]
        let credibility: Credibility
    }
}

struct MultimodalIngestionService {
    static let chunkSize = 8 * 1024 * 1024
    static let maxItems = 50
    static let maxFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxBatchBytes: Int64 = 5 * 1024 * 1024 * 1024

    let fluent: Fluent
    let vaultPaths: VaultPathService
    let linkCapture: LinkCaptureService
    let processor: HermesMultimodalProcessor
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let logger: Logger

    func create(tenantID: UUID, request: IngestionCreateRequest) async throws -> IngestionBatchDTO {
        guard !request.items.isEmpty, request.items.count <= Self.maxItems else {
            throw HTTPError(.badRequest, message: "ingestion batches require 1...\(Self.maxItems) items")
        }
        let batchBytes = request.items.compactMap(\.sizeBytes).reduce(Int64(0), +)
        guard batchBytes <= Self.maxBatchBytes else { throw HTTPError(.contentTooLarge, message: "batch exceeds 5 GiB") }
        if let spaceID = request.spaceID {
            guard try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == spaceID).first() != nil else {
                throw HTTPError(.badRequest, message: "unknown space")
            }
        }

        let batch = IngestionBatch(tenantID: tenantID, spaceID: request.spaceID)
        try await batch.save(on: fluent.db())
        let batchID = try batch.requireID()
        for input in request.items {
            try validate(input)
            let item = IngestionItem(
                tenantID: tenantID,
                batchID: batchID,
                kind: input.kind.rawValue,
                state: input.kind == .file ? IngestionItemStateDTO.awaitingUpload.rawValue : IngestionItemStateDTO.queued.rawValue,
                fileName: input.fileName,
                contentType: input.contentType,
                sizeBytes: input.sizeBytes,
                expectedSHA256: input.sha256?.lowercased(),
                url: input.url
            )
            try await item.save(on: fluent.db())
        }
        return try await detail(tenantID: tenantID, batchID: batchID)
    }

    func uploadChunk(tenantID: UUID, batchID: UUID, itemID: UUID, index: Int, data: Data) async throws {
        guard index >= 0, !data.isEmpty, data.count <= Self.chunkSize else {
            throw HTTPError(.badRequest, message: "invalid upload chunk")
        }
        let item = try await requireItem(tenantID: tenantID, batchID: batchID, itemID: itemID)
        guard item.state == IngestionItemStateDTO.awaitingUpload.rawValue else {
            throw HTTPError(.conflict, message: "item is not awaiting upload")
        }
        let directory = chunkDirectory(tenantID: tenantID, itemID: itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(String(index))
        if FileManager.default.fileExists(atPath: target.path) {
            let existing = try Data(contentsOf: target)
            guard existing == data else { throw HTTPError(.conflict, message: "chunk already exists with different bytes") }
            return
        }
        try data.write(to: target, options: .atomic)
        item.uploadedBytes += Int64(data.count)
        guard item.uploadedBytes <= (item.sizeBytes ?? Self.maxFileBytes) else {
            throw HTTPError(.contentTooLarge, message: "uploaded bytes exceed declared size")
        }
        try await item.save(on: fluent.db())
    }

    func complete(tenantID: UUID, batchID: UUID, itemID: UUID) async throws -> IngestionBatchDTO {
        let item = try await requireItem(tenantID: tenantID, batchID: batchID, itemID: itemID)
        guard item.state == IngestionItemStateDTO.awaitingUpload.rawValue else {
            return try await detail(tenantID: tenantID, batchID: batchID)
        }
        guard item.uploadedBytes == item.sizeBytes else { throw HTTPError(.badRequest, message: "upload is incomplete") }
        let batch = try await requireBatch(tenantID: tenantID, batchID: batchID)
        let fileID = try await assembleAndStore(item: item, batch: batch, tenantID: tenantID)
        item.vaultFileID = fileID
        item.state = IngestionItemStateDTO.queued.rawValue
        try await item.save(on: fluent.db())
        try? FileManager.default.removeItem(at: chunkDirectory(tenantID: tenantID, itemID: itemID))
        return try await detail(tenantID: tenantID, batchID: batchID)
    }

    func retry(tenantID: UUID, batchID: UUID, itemID: UUID) async throws -> IngestionBatchDTO {
        let batch = try await requireBatch(tenantID: tenantID, batchID: batchID)
        let item = try await requireItem(tenantID: tenantID, batchID: batchID, itemID: itemID)
        guard [IngestionItemStateDTO.failed.rawValue, IngestionItemStateDTO.blockedCapability.rawValue].contains(item.state) else {
            throw HTTPError(.conflict, message: "only failed or capability-blocked items can retry")
        }
        item.state = IngestionItemStateDTO.queued.rawValue
        item.errorMessage = nil
        try await item.save(on: fluent.db())
        return try await detail(tenantID: tenantID, batchID: batchID)
    }

    func cancel(tenantID: UUID, batchID: UUID, itemID: UUID) async throws -> IngestionBatchDTO {
        let item = try await requireItem(tenantID: tenantID, batchID: batchID, itemID: itemID)
        guard ![IngestionItemStateDTO.completed.rawValue, IngestionItemStateDTO.cancelled.rawValue].contains(item.state) else {
            return try await detail(tenantID: tenantID, batchID: batchID)
        }
        item.state = IngestionItemStateDTO.cancelled.rawValue
        item.errorMessage = nil
        try await item.save(on: fluent.db())
        try? FileManager.default.removeItem(at: chunkDirectory(tenantID: tenantID, itemID: itemID))
        try await refreshBatch(tenantID: tenantID, batchID: batchID)
        return try await detail(tenantID: tenantID, batchID: batchID)
    }

    @discardableResult
    func processNext() async throws -> Bool {
        guard let item = try await IngestionItem.query(on: fluent.db())
            .filter(\.$state == IngestionItemStateDTO.queued.rawValue)
            .sort(\.$createdAt, .ascending)
            .first()
        else { return false }
        let batch = try await requireBatch(tenantID: item.tenantID, batchID: item.batchID)
        try await process(item: item, tenantID: item.tenantID, spaceID: batch.spaceID)
        return true
    }

    func detail(tenantID: UUID, batchID: UUID) async throws -> IngestionBatchDTO {
        let batch = try await requireBatch(tenantID: tenantID, batchID: batchID)
        let items = try await IngestionItem.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$batchID == batchID).sort(\.$createdAt, .ascending).all()
        return try dto(batch: batch, items: items)
    }

    func list(tenantID: UUID) async throws -> IngestionBatchListDTO {
        let batches = try await IngestionBatch.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$createdAt, .descending).limit(50).all()
        var result: [IngestionBatchDTO] = []
        for batch in batches {
            try await result.append(detail(tenantID: tenantID, batchID: batch.requireID()))
        }
        return IngestionBatchListDTO(batches: result)
    }

    private func process(item: IngestionItem, tenantID: UUID, spaceID: UUID?) async throws {
        let source: String
        do {
            if item.kind == IngestionSourceKindDTO.url.rawValue, let url = item.url {
                if item.vaultFileID == nil {
                    let captured = try await linkCapture.captureLink(tenantID: tenantID, url: url, note: nil, spaceID: spaceID)
                    item.vaultFileID = captured.fileID
                }
                source = url
            } else if let vaultFileID = item.vaultFileID,
                      let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == vaultFileID).first()
            {
                source = vaultPaths.rawDirectory(for: tenantID).appendingPathComponent(row.path).path
            } else {
                throw HTTPError(.conflict, message: "item has no source")
            }
        } catch {
            item.state = IngestionItemStateDTO.failed.rawValue
            item.errorMessage = "Could not prepare source: \(String(describing: error).prefix(400))"
            try await item.save(on: fluent.db())
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }

        item.state = IngestionItemStateDTO.extracting.rawValue
        item.attempts += 1
        try await item.save(on: fluent.db())
        let result: HermesIngestionResult
        do {
            result = try await processor.process(
                tenantID: tenantID,
                source: source,
                contentType: item.contentType ?? (item.kind == "url" ? "text/html" : "application/octet-stream")
            )
        } catch {
            item.state = IngestionItemStateDTO.blockedCapability.rawValue
            item.errorMessage = "Hermes multimodal ingestion unavailable: \(String(describing: error).prefix(400))"
            try await item.save(on: fluent.db())
            logger.warning("ingestion blocked tenant=\(tenantID) item=\(String(describing: item.id)): \(error)")
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }

        if let current = try await IngestionItem.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == item.id).first(), current.state == IngestionItemStateDTO.cancelled.rawValue
        {
            return
        }
        do {
            item.state = IngestionItemStateDTO.saving.rawValue
            try await item.save(on: fluent.db())
            let sourceFileID = item.vaultFileID
            let content = "# \(result.title)\n\n\(result.markdown)\n\n## Source assessment\n\n\(result.credibility.rationale)"
            let embedding = try await embeddings.embed(content, tenantID: tenantID)
            let memory = try await memories.create(
                tenantID: tenantID, content: content, embedding: embedding, tags: result.tags,
                sourceVaultFileID: sourceFileID, spaceID: spaceID, reviewState: "auto"
            )
            item.memoryID = try memory.requireID()
            item.summary = result.summary
            item.credibility = result.credibility
            item.state = IngestionItemStateDTO.completed.rawValue
            item.errorMessage = nil
            try await item.save(on: fluent.db())
        } catch {
            item.state = IngestionItemStateDTO.failed.rawValue
            item.errorMessage = "Could not save derived memory: \(String(describing: error).prefix(400))"
            try await item.save(on: fluent.db())
            logger.warning("ingestion save failed tenant=\(tenantID) item=\(String(describing: item.id)): \(error)")
        }
        try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
    }

    private func assembleAndStore(item: IngestionItem, batch: IngestionBatch, tenantID: UUID) async throws -> UUID {
        guard let itemID = item.id, let fileName = item.fileName, let contentType = item.contentType else {
            throw HTTPError(.badRequest, message: "missing file metadata")
        }
        let safeName = Self.safeFileName((fileName as NSString).lastPathComponent)
        let folder: String = if let spaceID = batch.spaceID,
                                let space = try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == spaceID).first()
        {
            space.slug
        } else {
            "inbox"
        }
        let relative = try VaultController.sanitizePath("\(folder)/\(itemID.uuidString.lowercased())-\(safeName)")
        try VaultController.validateContentType(contentType, againstExtension: (safeName as NSString).pathExtension.lowercased())
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let target = try VaultController.resolveInside(rawRoot: vaultPaths.rawDirectory(for: tenantID), relative: relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.appendingPathExtension("assembling")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        var digest = SHA256()
        do {
            let chunks = try FileManager.default.contentsOfDirectory(at: chunkDirectory(tenantID: tenantID, itemID: itemID), includingPropertiesForKeys: nil)
                .sorted { Int($0.lastPathComponent) ?? 0 < Int($1.lastPathComponent) ?? 0 }
            for chunk in chunks {
                let data = try Data(contentsOf: chunk)
                try handle.write(contentsOf: data)
                digest.update(data: data)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = item.expectedSHA256, expected != sha {
            try? FileManager.default.removeItem(at: temp)
            throw HTTPError(.badRequest, message: "SHA-256 mismatch")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temp, to: target)
        let row = VaultFile(
            tenantID: tenantID, spaceID: batch.spaceID, path: relative,
            contentType: contentType, sizeBytes: item.sizeBytes ?? item.uploadedBytes, sha256: sha
        )
        try await row.save(on: fluent.db())
        return try row.requireID()
    }

    private func validate(_ item: IngestionCreateItemRequest) throws {
        switch item.kind {
        case .file:
            guard let name = item.fileName, !name.isEmpty, let type = item.contentType,
                  let size = item.sizeBytes, size > 0, size <= Self.maxFileBytes
            else { throw HTTPError(.badRequest, message: "file metadata is incomplete or too large") }
            _ = type
        case .url:
            guard let raw = item.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw HTTPError(.badRequest, message: "invalid URL ingestion item")
            }
        }
    }

    private func requireBatch(tenantID: UUID, batchID: UUID) async throws -> IngestionBatch {
        guard let batch = try await IngestionBatch.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == batchID).first()
        else { throw HTTPError(.notFound, message: "ingestion batch not found") }
        return batch
    }

    private func requireItem(tenantID: UUID, batchID: UUID, itemID: UUID) async throws -> IngestionItem {
        guard let item = try await IngestionItem.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$batchID == batchID).filter(\.$id == itemID).first()
        else { throw HTTPError(.notFound, message: "ingestion item not found") }
        return item
    }

    private func refreshBatch(tenantID: UUID, batchID: UUID) async throws {
        let batch = try await requireBatch(tenantID: tenantID, batchID: batchID)
        let states = try await IngestionItem.query(on: fluent.db(), tenantID: tenantID).filter(\.$batchID == batchID).all().map(\.state)
        if states.allSatisfy({ $0 == IngestionItemStateDTO.completed.rawValue }) {
            batch.state = "completed"
        } else if states.allSatisfy({ [IngestionItemStateDTO.completed.rawValue, IngestionItemStateDTO.failed.rawValue, IngestionItemStateDTO.blockedCapability.rawValue, IngestionItemStateDTO.cancelled.rawValue].contains($0) }) {
            batch.state = "attention"
        } else {
            batch.state = "active"
        }
        try await batch.save(on: fluent.db())
    }

    private func dto(batch: IngestionBatch, items: [IngestionItem]) throws -> IngestionBatchDTO {
        let mapped = try items.map { item in
            try IngestionItemDTO(
                id: item.requireID(), batchID: batch.requireID(),
                kind: IngestionSourceKindDTO(rawValue: item.kind) ?? .file,
                state: IngestionItemStateDTO(rawValue: item.state) ?? .failed,
                fileName: item.fileName, contentType: item.contentType, sizeBytes: item.sizeBytes,
                uploadedBytes: item.uploadedBytes, url: item.url, vaultFileID: item.vaultFileID,
                memoryID: item.memoryID, summary: item.summary, error: item.errorMessage,
                credibility: item.credibility.map { .init(score: $0.score, confidence: $0.confidence, signals: $0.signals, rationale: $0.rationale, version: $0.version) },
                createdAt: item.createdAt, updatedAt: item.updatedAt
            )
        }
        return try IngestionBatchDTO(
            id: batch.requireID(), state: batch.state, total: mapped.count,
            completed: mapped.count { $0.state == .completed }, failed: mapped.count { $0.state == .failed },
            chunkSizeBytes: Self.chunkSize, items: mapped, createdAt: batch.createdAt, updatedAt: batch.updatedAt
        )
    }

    private func chunkDirectory(tenantID: UUID, itemID: UUID) -> URL {
        vaultPaths.tenantRoot(for: tenantID).appendingPathComponent("tmp/ingestion/\(itemID.uuidString)")
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var result = ""
        var insertedDash = false
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                insertedDash = false
            } else if !insertedDash {
                result.append("-")
                insertedDash = true
            }
        }
        return String(result.prefix(180)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
