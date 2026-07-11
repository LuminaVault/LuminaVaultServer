import FluentKit
import Foundation
import LuminaVaultShared

final class MarketplacePublisher: Model, @unchecked Sendable {
    static let schema = "marketplace_publishers"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_user_id") var ownerUserID: UUID
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "bio") var bio: String?
    @OptionalField(key: "website_url") var websiteURL: String?
    @Field(key: "status") var status: String
    @Field(key: "verified") var verified: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(ownerUserID: UUID, handle: String, displayName: String, bio: String?, websiteURL: String?) {
        self.ownerUserID = ownerUserID
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        self.websiteURL = websiteURL
        status = "pending"
        verified = false
    }
}

final class MarketplaceListing: Model, @unchecked Sendable {
    static let schema = "marketplace_listings"

    @ID(key: .id) var id: UUID?
    @Field(key: "publisher_id") var publisherID: UUID
    @Field(key: "slug") var slug: String
    @Field(key: "name") var name: String
    @Field(key: "summary") var summary: String
    @Field(key: "description") var descriptionText: String
    @Field(key: "category") var category: String
    @OptionalField(key: "icon_url") var iconURL: String?
    @Field(key: "screenshots") var screenshots: [String]
    @Field(key: "status") var status: String
    @Field(key: "featured") var featured: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class MarketplaceVersion: Model, @unchecked Sendable {
    static let schema = "marketplace_versions"

    @ID(key: .id) var id: UUID?
    @Field(key: "listing_id") var listingID: UUID
    @Field(key: "version") var version: String
    @Field(key: "status") var status: String
    @Field(key: "runtime_kind") var runtimeKind: String
    @Field(key: "permissions") var permissions: [String]
    @Field(key: "network_hosts") var networkHosts: [String]
    @Field(key: "config_fields") var configFields: [PluginConfigField]
    @OptionalField(key: "changelog") var changelog: String?
    @OptionalField(key: "artifact_key") var artifactKey: String?
    @OptionalField(key: "artifact_sha256") var artifactSHA256: String?
    @OptionalField(key: "artifact_signature") var artifactSignature: String?
    @OptionalField(key: "manifest_json") var manifestJSON: Data?
    @OptionalField(key: "published_at") var publishedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class MarketplaceSubmission: Model, @unchecked Sendable {
    static let schema = "marketplace_submissions"

    @ID(key: .id) var id: UUID?
    @Field(key: "version_id") var versionID: UUID
    @Field(key: "publisher_user_id") var publisherUserID: UUID
    @Field(key: "status") var status: String
    @Field(key: "validation_errors") var validationErrors: [String]
    @OptionalField(key: "review_note") var reviewNote: String?
    @OptionalField(key: "reviewed_by_user_id") var reviewedByUserID: UUID?
    @OptionalField(key: "submitted_at") var submittedAt: Date?
    @OptionalField(key: "reviewed_at") var reviewedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class MarketplaceRating: Model, @unchecked Sendable {
    static let schema = "marketplace_ratings"

    @ID(key: .id) var id: UUID?
    @Field(key: "listing_id") var listingID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "rating") var rating: Int
    @OptionalField(key: "body") var body: String?
    @Field(key: "moderation_status") var moderationStatus: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class MarketplaceExecution: Model, TenantModel, @unchecked Sendable {
    static let schema = "marketplace_executions"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "install_id") var installID: UUID
    @Field(key: "version_id") var versionID: UUID
    @Field(key: "tool_name") var toolName: String
    @Field(key: "status") var status: String
    @OptionalField(key: "error_code") var errorCode: String?
    @OptionalField(key: "duration_ms") var durationMS: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
