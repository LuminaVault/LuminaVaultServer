import FluentKit
import Foundation

/// One item inside an `ImportSession` (a bookmark/link, a document, a photo…).
/// Links to the `vault_files` row created while staging, and carries the
/// LLM's proposed Space until the user approves the mapping.
final class ImportItem: Model, TenantModel, @unchecked Sendable {
    static let schema = "import_items"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "session_id") var sessionID: UUID
    /// The staged vault file (nil if staging failed / item was skipped).
    @OptionalField(key: "vault_file_id") var vaultFileID: UUID?
    @OptionalField(key: "url") var url: String?
    @OptionalField(key: "title") var title: String?
    /// Smart Import target: an existing Space slug, or `new:<Name>` for a
    /// proposed new Space, or nil/`imported` for the inbox. Set by
    /// `ImportCategorizationService`, edited by the user on the review screen.
    @OptionalField(key: "proposed_space") var proposedSpace: String?
    /// `staged` | `enriched` | `categorized` | `filed` | `skipped` | `failed`
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        sessionID: UUID,
        vaultFileID: UUID? = nil,
        url: String? = nil,
        title: String? = nil,
        proposedSpace: String? = nil,
        status: String = "staged"
    ) {
        self.id = id
        self.tenantID = tenantID
        self.sessionID = sessionID
        self.vaultFileID = vaultFileID
        self.url = url
        self.title = title
        self.proposedSpace = proposedSpace
        self.status = status
    }
}

enum ImportItemStatus {
    static let staged = "staged"
    static let enriched = "enriched"
    static let categorized = "categorized"
    static let filed = "filed"
    static let skipped = "skipped"
    static let failed = "failed"
}
