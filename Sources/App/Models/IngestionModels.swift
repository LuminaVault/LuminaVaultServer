import FluentKit
import Foundation

final class IngestionBatch: Model, TenantModel, @unchecked Sendable {
    static let schema = "ingestion_batches"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @OptionalField(key: "space_id") var spaceID: UUID?
    @Field(key: "state") var state: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, tenantID: UUID, spaceID: UUID? = nil, state: String = "active") {
        self.id = id
        self.tenantID = tenantID
        self.spaceID = spaceID
        self.state = state
    }
}

struct IngestionCredibilityRecord: Codable {
    let score: Int?
    let confidence: Double
    let signals: [String]
    let rationale: String
    let version: String
}

final class IngestionItem: Model, TenantModel, @unchecked Sendable {
    static let schema = "ingestion_items"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "batch_id") var batchID: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "state") var state: String
    @OptionalField(key: "file_name") var fileName: String?
    @OptionalField(key: "content_type") var contentType: String?
    @OptionalField(key: "size_bytes") var sizeBytes: Int64?
    @Field(key: "uploaded_bytes") var uploadedBytes: Int64
    @OptionalField(key: "expected_sha256") var expectedSHA256: String?
    @OptionalField(key: "url") var url: String?
    @OptionalField(key: "vault_file_id") var vaultFileID: UUID?
    @OptionalField(key: "memory_id") var memoryID: UUID?
    @OptionalField(key: "summary") var summary: String?
    @OptionalField(key: "error_message") var errorMessage: String?
    @OptionalField(key: "credibility") var credibility: IngestionCredibilityRecord?
    @Field(key: "attempts") var attempts: Int
    @OptionalField(key: "next_attempt_at") var nextAttemptAt: Date?
    @OptionalField(key: "lease_expires_at") var leaseExpiresAt: Date?
    @OptionalField(key: "source_token_hash") var sourceTokenHash: String?
    @OptionalField(key: "source_token_expires_at") var sourceTokenExpiresAt: Date?
    @OptionalField(key: "content_sha256") var contentSHA256: String?
    @Field(key: "pipeline_version") var pipelineVersion: String
    @OptionalField(key: "reused_from_item_id") var reusedFromItemID: UUID?
    @OptionalField(key: "graph_ready_at") var graphReadyAt: Date?
    @OptionalField(key: "terminal_notified_at") var terminalNotifiedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        tenantID: UUID,
        batchID: UUID,
        kind: String,
        state: String,
        fileName: String? = nil,
        contentType: String? = nil,
        sizeBytes: Int64? = nil,
        expectedSHA256: String? = nil,
        url: String? = nil
    ) {
        self.tenantID = tenantID
        self.batchID = batchID
        self.kind = kind
        self.state = state
        self.fileName = fileName
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        uploadedBytes = 0
        self.expectedSHA256 = expectedSHA256
        self.url = url
        attempts = 0
        nextAttemptAt = nil
        leaseExpiresAt = nil
        sourceTokenHash = nil
        sourceTokenExpiresAt = nil
        contentSHA256 = nil
        pipelineVersion = "multimodal-v2"
        reusedFromItemID = nil
        graphReadyAt = nil
        terminalNotifiedAt = nil
    }
}
