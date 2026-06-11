import FluentKit
import Foundation

/// HER-290 — see `M54_CreateKBCompileRejectList` for the table description.
final class KBCompileRejectListEntry: Model, TenantModel, @unchecked Sendable {
    static let schema = "kb_compile_reject_list"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "content_hash") var contentHash: String
    @OptionalField(key: "vault_file_id") var vaultFileID: UUID?
    @Field(key: "rejected_at") var rejectedAt: Date

    init() {
        rejectedAt = Date()
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        contentHash: String,
        vaultFileID: UUID? = nil,
        rejectedAt: Date = Date()
    ) {
        self.id = id
        self.tenantID = tenantID
        self.contentHash = contentHash
        self.vaultFileID = vaultFileID
        self.rejectedAt = rejectedAt
    }
}
