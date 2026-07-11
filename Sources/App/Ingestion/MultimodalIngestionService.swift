import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

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
    static let processingLeaseSeconds = 60 * 60
    static let maximumAutomaticAttempts = 3
    static let abandonedUploadHours = 24

    let fluent: Fluent
    let vaultPaths: VaultPathService
    let linkCapture: LinkCaptureService
    let processor: HermesMultimodalProcessor
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let logger: Logger
    let ingestionCapabilities: @Sendable (UUID) async -> HermesCapabilities
    let publicBaseURL: URL?

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
        _ = try await requireBatch(tenantID: tenantID, batchID: batchID)
        let item = try await requireItem(tenantID: tenantID, batchID: batchID, itemID: itemID)
        guard [IngestionItemStateDTO.failed.rawValue, IngestionItemStateDTO.blockedCapability.rawValue].contains(item.state) else {
            throw HTTPError(.conflict, message: "only failed or capability-blocked items can retry")
        }
        item.state = IngestionItemStateDTO.queued.rawValue
        item.errorMessage = nil
        item.nextAttemptAt = nil
        item.leaseExpiresAt = nil
        item.sourceTokenHash = nil
        item.sourceTokenExpiresAt = nil
        try await item.save(on: fluent.db())
        try await refreshBatch(tenantID: tenantID, batchID: batchID)
        return try await detail(tenantID: tenantID, batchID: batchID)
    }

    func cancel(tenantID: UUID, batchID: UUID, itemID: UUID) async throws -> IngestionBatchDTO {
        let item = try await requireItem(tenantID: tenantID, batchID: batchID, itemID: itemID)
        guard ![IngestionItemStateDTO.completed.rawValue, IngestionItemStateDTO.cancelled.rawValue].contains(item.state) else {
            return try await detail(tenantID: tenantID, batchID: batchID)
        }
        item.state = IngestionItemStateDTO.cancelled.rawValue
        item.errorMessage = nil
        item.nextAttemptAt = nil
        item.leaseExpiresAt = nil
        item.sourceTokenHash = nil
        item.sourceTokenExpiresAt = nil
        try await item.save(on: fluent.db())
        try? FileManager.default.removeItem(at: chunkDirectory(tenantID: tenantID, itemID: itemID))
        try await refreshBatch(tenantID: tenantID, batchID: batchID)
        return try await detail(tenantID: tenantID, batchID: batchID)
    }

    @discardableResult
    func processNext() async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else { return false }
        try await recoverExpiredWork(sql: sql)
        try await expireAbandonedUploads(sql: sql)
        struct ClaimedItem: Decodable { let id: UUID }
        guard let claim = try await sql.raw("""
        WITH candidate AS (
            SELECT id FROM ingestion_items
            WHERE state = 'queued' AND (next_attempt_at IS NULL OR next_attempt_at <= NOW())
            ORDER BY created_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        UPDATE ingestion_items item
        SET state = 'extracting', attempts = attempts + 1,
            lease_expires_at = NOW() + (\(bind: Self.processingLeaseSeconds) * INTERVAL '1 second'),
            updated_at = NOW()
        FROM candidate
        WHERE item.id = candidate.id
        RETURNING item.id
        """).first(decoding: ClaimedItem.self),
            let item = try await IngestionItem.query(on: fluent.db()).filter(\.$id == claim.id).first()
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
        let capabilities = await ingestionCapabilities(tenantID)
        if capabilities.multimodalIngestion == .unsupported {
            item.state = IngestionItemStateDTO.blockedCapability.rawValue
            item.leaseExpiresAt = nil
            item.errorMessage = capabilities.ingestionRemoteSourceURL == true
                ? "Connected Hermes advertises remote sources but not multimodal ingestion. Upgrade or enable its ingestion API."
                : "Connected Hermes does not advertise multimodal ingestion with remote source URLs. Upgrade Hermes or use managed processing."
            try await item.save(on: fluent.db())
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }
        if let maximum = capabilities.ingestionMaxSourceBytes,
           let size = item.sizeBytes, size > maximum
        {
            item.state = IngestionItemStateDTO.blockedCapability.rawValue
            item.leaseExpiresAt = nil
            item.errorMessage = "Connected Hermes accepts sources up to \(maximum) bytes."
            try await item.save(on: fluent.db())
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }
        if let supported = capabilities.ingestionSupportedMimeTypes,
           let contentType = item.contentType,
           !Self.supports(contentType: contentType, patterns: supported)
        {
            item.state = IngestionItemStateDTO.blockedCapability.rawValue
            item.leaseExpiresAt = nil
            item.errorMessage = "Connected Hermes does not support \(contentType)."
            try await item.save(on: fluent.db())
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }
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
                if capabilities.isUserOverride, capabilities.ingestionRemoteSourceURL == true {
                    guard let publicBaseURL else {
                        throw HTTPError(.serviceUnavailable, message: "INGESTION_PUBLIC_BASE_URL is required for BYO Hermes file ingestion")
                    }
                    let token = Self.randomSourceToken()
                    item.sourceTokenHash = Self.sourceTokenHash(token)
                    item.sourceTokenExpiresAt = Date().addingTimeInterval(TimeInterval(Self.processingLeaseSeconds))
                    try await item.save(on: fluent.db())
                    source = publicBaseURL
                        .appendingPathComponent("v1/ingestion-sources")
                        .appendingPathComponent(token)
                        .absoluteString
                } else {
                    source = vaultPaths.rawDirectory(for: tenantID).appendingPathComponent(row.path).path
                }
            } else {
                throw HTTPError(.conflict, message: "item has no source")
            }
        } catch {
            item.state = IngestionItemStateDTO.failed.rawValue
            item.leaseExpiresAt = nil
            item.sourceTokenHash = nil
            item.sourceTokenExpiresAt = nil
            item.errorMessage = "Could not prepare source: \(String(describing: error).prefix(400))"
            try await item.save(on: fluent.db())
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }

        let result: HermesIngestionResult
        do {
            result = try await processor.process(
                tenantID: tenantID,
                source: source,
                contentType: item.contentType ?? (item.kind == "url" ? "text/html" : "application/octet-stream")
            )
        } catch {
            let shouldRetry = item.attempts < Self.maximumAutomaticAttempts
            item.state = shouldRetry ? IngestionItemStateDTO.queued.rawValue : IngestionItemStateDTO.blockedCapability.rawValue
            item.nextAttemptAt = shouldRetry ? Date().addingTimeInterval(Self.retryDelay(for: item.attempts)) : nil
            item.leaseExpiresAt = nil
            item.sourceTokenHash = nil
            item.sourceTokenExpiresAt = nil
            item.errorMessage = shouldRetry
                ? "Hermes processing deferred: \(String(describing: error).prefix(400))"
                : "Hermes multimodal ingestion unavailable after \(item.attempts) attempts: \(String(describing: error).prefix(400))"
            try await item.save(on: fluent.db())
            logger.warning("ingestion blocked tenant=\(tenantID) item=\(String(describing: item.id)): \(error)")
            try await refreshBatch(tenantID: tenantID, batchID: item.batchID)
            return
        }

        if let current = try await IngestionItem.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == item.requireID()).first(), current.state == IngestionItemStateDTO.cancelled.rawValue
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
            item.nextAttemptAt = nil
            item.leaseExpiresAt = nil
            item.sourceTokenHash = nil
            item.sourceTokenExpiresAt = nil
            try await item.save(on: fluent.db())
        } catch {
            item.state = IngestionItemStateDTO.failed.rawValue
            item.leaseExpiresAt = nil
            item.sourceTokenHash = nil
            item.sourceTokenExpiresAt = nil
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

    private func recoverExpiredWork(sql: any SQLDatabase) async throws {
        try await sql.raw("""
        UPDATE ingestion_items
        SET state = 'queued', next_attempt_at = NOW(), lease_expires_at = NULL,
            error_message = 'Recovered after an interrupted worker lease', updated_at = NOW()
        WHERE state IN ('extracting', 'analyzing', 'saving')
          AND lease_expires_at IS NOT NULL AND lease_expires_at <= NOW()
        """).run()
    }

    private func expireAbandonedUploads(sql: any SQLDatabase) async throws {
        struct StaleUpload: Decodable { let id: UUID; let tenant_id: UUID; let batch_id: UUID }
        let stale = try await sql.raw("""
        UPDATE ingestion_items
        SET state = 'failed', error_message = 'Upload expired after 24 hours', updated_at = NOW()
        WHERE state = 'awaiting_upload'
          AND updated_at < NOW() - (\(bind: Self.abandonedUploadHours) * INTERVAL '1 hour')
        RETURNING id, tenant_id, batch_id
        """).all(decoding: StaleUpload.self)
        for item in stale {
            try? FileManager.default.removeItem(at: chunkDirectory(tenantID: item.tenant_id, itemID: item.id))
        }
        for item in Dictionary(grouping: stale, by: \.batch_id).values.compactMap(\.first) {
            try await refreshBatch(tenantID: item.tenant_id, batchID: item.batch_id)
        }
    }

    private static func retryDelay(for attempt: Int) -> TimeInterval {
        TimeInterval(min(300, 1 << min(max(0, attempt), 8)))
    }

    static func supports(contentType: String, patterns: [String]) -> Bool {
        let value = contentType.lowercased()
        return patterns.contains { pattern in
            let normalized = pattern.lowercased()
            if normalized.hasSuffix("/*") {
                return value.hasPrefix(String(normalized.dropLast()))
            }
            return value == normalized
        }
    }

    func source(token: String) async throws -> (data: Data, contentType: String, fileName: String) {
        guard token.count == 64,
              let item = try await IngestionItem.query(on: fluent.db())
              .filter(\.$sourceTokenHash == Self.sourceTokenHash(token)).first(),
              let expiry = item.sourceTokenExpiresAt, expiry > Date(),
              let vaultFileID = item.vaultFileID,
              let row = try await VaultFile.query(on: fluent.db(), tenantID: item.tenantID)
              .filter(\.$id == vaultFileID).first()
        else { throw HTTPError(.notFound, message: "ingestion source not found or expired") }
        let target = vaultPaths.rawDirectory(for: item.tenantID).appendingPathComponent(row.path)
        guard FileManager.default.fileExists(atPath: target.path) else { throw HTTPError(.notFound) }
        return (try Data(contentsOf: target), row.contentType, item.fileName ?? "source")
    }

    static func sourceTokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSourceToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
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
