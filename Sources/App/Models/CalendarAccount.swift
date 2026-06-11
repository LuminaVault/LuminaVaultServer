import FluentKit
import Foundation

/// HER-340 — per-tenant connected calendar account (Phase 1: Google).
///
/// Holds the OAuth tokens for a single external calendar provider plus the
/// incremental-sync bookkeeping. Refresh + access tokens are sealed via
/// `SecretBox` (AES-GCM, per-tenant HKDF key) into the `*_ciphertext` /
/// `*_nonce` pairs — plaintext never hits the DB or logs. `accessExpiresAt`
/// lets `CalendarTokenStore` decide when to refresh.
///
/// `syncToken` is Google's opaque incremental cursor (from `events.list`
/// `nextSyncToken`); a `410 Gone` invalidates it and forces a window
/// re-sync. `windowStart`/`windowEnd` bound the rolling cache range.
///
/// `status`: "connected" | "needs_reauth" (refresh failed / externally
/// revoked) — the iOS pane reads this to prompt a reconnect.
///
/// FK `ON DELETE CASCADE` to `users.id`. Unique `(tenant_id, provider)`
/// enforces one account per provider per tenant (see `M79_CreateCalendar`).
final class CalendarAccount: Model, TenantModel, @unchecked Sendable {
    static let schema = "calendar_accounts"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "provider") var provider: String
    @OptionalField(key: "account_email") var accountEmail: String?
    @Field(key: "scope") var scope: String

    @OptionalField(key: "refresh_ciphertext") var refreshCiphertext: Data?
    @OptionalField(key: "refresh_nonce") var refreshNonce: Data?
    @OptionalField(key: "access_ciphertext") var accessCiphertext: Data?
    @OptionalField(key: "access_nonce") var accessNonce: Data?
    @OptionalField(key: "access_expires_at") var accessExpiresAt: Date?

    @OptionalField(key: "sync_token") var syncToken: String?
    @OptionalField(key: "last_synced_at") var lastSyncedAt: Date?
    @OptionalField(key: "window_start") var windowStart: Date?
    @OptionalField(key: "window_end") var windowEnd: Date?

    @Field(key: "status") var status: String
    @OptionalField(key: "last_failure_at") var lastFailureAt: Date?
    @OptionalField(key: "last_failure_code") var lastFailureCode: String?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        provider: String = "google",
        accountEmail: String? = nil,
        scope: String,
        status: String = "connected"
    ) {
        self.id = id
        self.tenantID = tenantID
        self.provider = provider
        self.accountEmail = accountEmail
        self.scope = scope
        self.status = status
    }
}
