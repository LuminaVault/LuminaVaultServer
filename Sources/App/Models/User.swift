import FluentKit
import Foundation

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "username") var username: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "is_verified") var isVerified: Bool
    @Field(key: "failed_login_attempts") var failedLoginAttempts: Int
    @OptionalField(key: "lockout_until") var lockoutUntil: Date?
    @Field(key: "tier") var tier: String
    @OptionalField(key: "tier_expires_at") var tierExpiresAt: Date?
    @Field(key: "tier_override") var tierOverride: String
    @OptionalField(key: "revenuecat_user_id") var revenuecatUserID: String?
    /// HER-172 opt-in flag for the ContextRouter middleware. Default false
    /// because the routing call burns a `capability=low` LLM hit per chat
    /// message — only acceptable for paid tiers.
    @Field(key: "context_routing") var contextRouting: Bool
    /// HER-176 opt-out flag that excludes CN-origin weights from
    /// `ModelRouter.pick` (DeepSeek/Qwen/Kimi). Default false. ON forces
    /// routing onto more expensive US/EU-origin models — documented trade-off
    /// surfaced in iOS Settings.
    @Field(key: "privacy_no_cn_origin") var privacyNoCNOrigin: Bool
    /// HER-170 — IANA timezone name (e.g. "Europe/Lisbon"). CronScheduler
    /// resolves each user's skill schedules in this zone so `0 7 * * *`
    /// fires at 07:00 LOCAL, not 07:00 UTC. Defaults to "UTC" when iOS
    /// hasn't sent one yet (older clients).
    @Field(key: "timezone") var timezone: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {
        contextRouting = false
        privacyNoCNOrigin = false
        timezone = "UTC"
    }

    init(
        id: UUID? = nil,
        email: String,
        username: String,
        passwordHash: String,
        isVerified: Bool = false,
        failedLoginAttempts: Int = 0,
        lockoutUntil: Date? = nil,
        tier: String = "trial",
        tierExpiresAt: Date? = nil,
        tierOverride: String = "none",
        revenuecatUserID: String? = nil,
    ) {
        self.id = id
        self.email = email.lowercased()
        self.username = username.trimmingCharacters(in: .whitespaces).lowercased()
        self.passwordHash = passwordHash
        self.isVerified = isVerified
        self.failedLoginAttempts = failedLoginAttempts
        self.lockoutUntil = lockoutUntil
        self.tier = tier
        self.tierExpiresAt = tierExpiresAt
        self.tierOverride = tierOverride
        self.revenuecatUserID = revenuecatUserID
        contextRouting = false
        privacyNoCNOrigin = false
        timezone = "UTC"
    }
}
