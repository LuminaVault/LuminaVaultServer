import FluentKit
import Foundation

/// HER-147 cold-storage mirror of `Memory`. The pruning job writes here;
/// nothing in the live request path queries this table. Kept as a Fluent
/// model so account deletion (HER-92) and admin tooling can iterate
/// without dropping into raw SQL.
final class MemoryArchive: Model, TenantModel, @unchecked Sendable {
    static let schema = "memories_archive"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "content") var content: String
    @OptionalField(key: "tags") var tags: [String]?
    @Field(key: "score") var score: Double
    @Field(key: "access_count") var accessCount: Int64
    @Field(key: "query_hit_count") var queryHitCount: Int64
    @OptionalField(key: "last_accessed_at") var lastAccessedAt: Date?
    @OptionalField(key: "created_at") var originalCreatedAt: Date?
    @Field(key: "archived_at") var archivedAt: Date

    init() {
        self.score = 0
        self.accessCount = 0
        self.queryHitCount = 0
        self.archivedAt = Date()
    }
}
