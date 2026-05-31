import FluentKit
import Foundation

/// JSON sidecar on each vault row. All fields optional so older rows (which
/// only ever held `enrichmentStatus`) decode cleanly — a missing key is nil.
/// HER-Notes adds the note/smart-todo fields: a human title, free-form tags,
/// and todo state (isTodo + done + dueAt) so a note can act as a diary entry
/// or a checkable, due-dated task.
struct VaultFileMetadata: Codable {
    var enrichmentStatus: String?
    var title: String?
    var tags: [String]?
    var isTodo: Bool?
    var done: Bool?
    var dueAt: Date?
    /// HER-Notes/Todos merge — optional Project grouping (maps to
    /// `TodoDTO.projectID`). Stored here so note-todos and the dedicated
    /// `/v1/todos` API share one backing store (the vault file).
    var projectID: UUID?

    init(
        enrichmentStatus: String? = nil,
        title: String? = nil,
        tags: [String]? = nil,
        isTodo: Bool? = nil,
        done: Bool? = nil,
        dueAt: Date? = nil,
        projectID: UUID? = nil,
    ) {
        self.enrichmentStatus = enrichmentStatus
        self.title = title
        self.tags = tags
        self.isTodo = isTodo
        self.done = done
        self.dueAt = dueAt
        self.projectID = projectID
    }
}

/// Tracks every file persisted under `<rawRoot>/<path>` for the tenant.
/// DB row exists alongside the on-disk blob — the row is the index, the
/// disk file is the payload. Path is unique per tenant; updating the
/// same path replaces the row in place.
final class VaultFile: Model, TenantModel, @unchecked Sendable {
    static let schema = "vault_files"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @OptionalField(key: "space_id") var spaceID: UUID?
    @Field(key: "path") var path: String
    @Field(key: "content_type") var contentType: String
    @Field(key: "size_bytes") var sizeBytes: Int64
    @Field(key: "sha256") var sha256: String
    @OptionalField(key: "processed_at") var processedAt: Date?
    @OptionalField(key: "metadata") var metadata: VaultFileMetadata?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        spaceID: UUID? = nil,
        path: String,
        contentType: String,
        sizeBytes: Int64,
        sha256: String,
        processedAt: Date? = nil,
        metadata: VaultFileMetadata? = nil,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.spaceID = spaceID
        self.path = path
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.processedAt = processedAt
        self.metadata = metadata
    }
}
