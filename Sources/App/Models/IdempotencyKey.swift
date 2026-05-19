import FluentKit
import Foundation

/// HER-39 — server-side cache of mutating-request results, keyed per tenant +
/// client-supplied `Idempotency-Key` header. Lets the iOS sync queue replay
/// queued operations after a network drop without double-creating rows.
///
/// Lifecycle: row is written on the first successful completion of an
/// `Idempotency-Key`-tagged mutating request. Replays with the same `(tenant_id,
/// key)` return the cached body. Replays whose request hash differs from the
/// stored hash get 409 (caller bug — same key, different request). Rows expire
/// 24 h after creation; an out-of-band janitor (follow-up ticket) reaps them.
final class IdempotencyKey: Model, TenantModel, @unchecked Sendable {
    static let schema = "idempotency_keys"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "key") var key: UUID
    @Field(key: "request_hash") var requestHash: String
    @Field(key: "response_status") var responseStatus: Int
    @OptionalField(key: "response_content_type") var responseContentType: String?
    @Field(key: "response_body") var responseBody: Data
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "expires_at") var expiresAt: Date

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        key: UUID,
        requestHash: String,
        responseStatus: Int,
        responseContentType: String?,
        responseBody: Data,
        expiresAt: Date,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.key = key
        self.requestHash = requestHash
        self.responseStatus = responseStatus
        self.responseContentType = responseContentType
        self.responseBody = responseBody
        self.expiresAt = expiresAt
    }
}
