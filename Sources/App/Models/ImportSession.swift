import FluentKit
import Foundation

/// "Feed Your Brain" — one bulk import run (bookmarks file, pasted URLs, photos,
/// documents, reminders…). Tracks the batch through its lifecycle so the client
/// can poll/stream progress and present the Smart Import review screen.
///
/// `status` lifecycle:
///   staging → enriching → categorizing → review → filing → compiling → done
/// (`failed` on a fatal error). Items land in the reserved `imported` inbox
/// Space while staging; they only move into their final Space on approval.
final class ImportSession: Model, TenantModel, @unchecked Sendable {
    static let schema = "import_sessions"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    /// `bookmarks` | `documents` | `photos` | `reminders` | `calendar` | `mixed`
    @Field(key: "source_type") var sourceType: String
    @Field(key: "status") var status: String
    @Field(key: "total_items") var totalItems: Int
    @Field(key: "staged_items") var stagedItems: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        sourceType: String,
        status: String = "staging",
        totalItems: Int = 0,
        stagedItems: Int = 0
    ) {
        self.id = id
        self.tenantID = tenantID
        self.sourceType = sourceType
        self.status = status
        self.totalItems = totalItems
        self.stagedItems = stagedItems
    }
}

enum ImportStatus {
    static let staging = "staging"
    static let enriching = "enriching"
    static let categorizing = "categorizing"
    static let review = "review"
    static let filing = "filing"
    static let compiling = "compiling"
    static let done = "done"
    static let failed = "failed"
}
