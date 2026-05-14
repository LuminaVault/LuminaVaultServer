import FluentKit
import Foundation

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
    ) {
        self.id = id
        self.tenantID = tenantID
        self.spaceID = spaceID
        self.path = path
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.processedAt = processedAt
    }
}
