import FluentKit
import Foundation

final class Memory: Model, TenantModel, @unchecked Sendable {
    static let schema = "memories"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "content") var content: String
    @OptionalField(key: "tags") var tags: [String]?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, tenantID: UUID, content: String, tags: [String]? = nil) {
        self.id = id
        self.tenantID = tenantID
        self.content = content
        self.tags = tags
    }
}
