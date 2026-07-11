import FluentKit
import Foundation

final class MemorySyncTombstone: Model, TenantModel, @unchecked Sendable {
    static let schema = "memory_sync_tombstones"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "memory_id") var memoryID: UUID
    @Timestamp(key: "deleted_at", on: .create) var deletedAt: Date?

    init() {}
    init(tenantID: UUID, memoryID: UUID) {
        self.tenantID = tenantID
        self.memoryID = memoryID
    }
}
