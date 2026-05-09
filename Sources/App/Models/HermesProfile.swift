import FluentKit
import Foundation

final class HermesProfile: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_profiles"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "hermes_profile_id") var hermesProfileID: String
    @Field(key: "status") var status: String              // provisioning | ready | error
    @OptionalField(key: "last_error") var lastError: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, hermesProfileID: String, status: String) {
        self.tenantID = tenantID
        self.hermesProfileID = hermesProfileID
        self.status = status
    }
}
