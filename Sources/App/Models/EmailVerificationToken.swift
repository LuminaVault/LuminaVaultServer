import FluentKit
import Foundation

final class EmailVerificationToken: Model, TenantModel, @unchecked Sendable {
    static let schema = "email_verification_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "used_at") var usedAt: Date?
    @Field(key: "failed_attempts") var failedAttempts: Int
    @OptionalField(key: "locked_until") var lockedUntil: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, tenantID: UUID, codeHash: String, expiresAt: Date) {
        self.id = id
        self.tenantID = tenantID
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        failedAttempts = 0
    }
}
