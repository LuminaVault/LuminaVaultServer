import FluentKit
import Foundation

final class MFAChallenge: Model, TenantModel, @unchecked Sendable {
    static let schema = "mfa_challenges"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "purpose") var purpose: String
    @Field(key: "channel") var channel: String
    @Field(key: "destination") var destination: String
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "consumed_at") var consumedAt: Date?
    @Field(key: "failed_attempts") var failedAttempts: Int
    @Field(key: "resend_count") var resendCount: Int
    @OptionalField(key: "last_sent_at") var lastSentAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        purpose: String,
        channel: String,
        destination: String,
        codeHash: String,
        expiresAt: Date
    ) {
        self.id = id
        self.tenantID = tenantID
        self.purpose = purpose
        self.channel = channel
        self.destination = destination
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.failedAttempts = 0
        self.resendCount = 0
    }
}
