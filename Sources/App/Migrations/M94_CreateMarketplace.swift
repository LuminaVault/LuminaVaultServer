import FluentKit
import Foundation
import LuminaVaultShared

struct M94_CreateMarketplace: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MarketplacePublisher.schema)
            .id()
            .field("owner_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("handle", .string, .required)
            .field("display_name", .string, .required)
            .field("bio", .string)
            .field("website_url", .string)
            .field("status", .string, .required)
            .field("verified", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "owner_user_id")
            .unique(on: "handle")
            .create()

        try await database.schema(MarketplaceListing.schema)
            .id()
            .field("publisher_id", .uuid, .required, .references(MarketplacePublisher.schema, "id", onDelete: .cascade))
            .field("slug", .string, .required)
            .field("name", .string, .required)
            .field("summary", .string, .required)
            .field("description", .string, .required)
            .field("category", .string, .required)
            .field("icon_url", .string)
            .field("screenshots", .array(of: .string), .required)
            .field("status", .string, .required)
            .field("featured", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "slug")
            .create()

        try await database.schema(MarketplaceVersion.schema)
            .id()
            .field("listing_id", .uuid, .required, .references(MarketplaceListing.schema, "id", onDelete: .cascade))
            .field("version", .string, .required)
            .field("status", .string, .required)
            .field("runtime_kind", .string, .required)
            .field("permissions", .array(of: .string), .required)
            .field("network_hosts", .array(of: .string), .required)
            .field("config_fields", .json, .required)
            .field("changelog", .string)
            .field("artifact_key", .string)
            .field("artifact_sha256", .string)
            .field("artifact_signature", .string)
            .field("manifest_json", .data)
            .field("published_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "listing_id", "version")
            .create()

        try await database.schema(MarketplaceSubmission.schema)
            .id()
            .field("version_id", .uuid, .required, .references(MarketplaceVersion.schema, "id", onDelete: .cascade))
            .field("publisher_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("validation_errors", .array(of: .string), .required)
            .field("review_note", .string)
            .field("reviewed_by_user_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("submitted_at", .datetime)
            .field("reviewed_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "version_id")
            .create()

        try await database.schema(MarketplaceRating.schema)
            .id()
            .field("listing_id", .uuid, .required, .references(MarketplaceListing.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("rating", .int, .required)
            .field("body", .string)
            .field("moderation_status", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "listing_id", "user_id")
            .create()

        try await database.schema(MarketplaceExecution.schema)
            .id()
            .field("tenant_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("install_id", .uuid, .required, .references(PluginInstall.schema, "id", onDelete: .cascade))
            .field("version_id", .uuid, .required, .references(MarketplaceVersion.schema, "id", onDelete: .restrict))
            .field("tool_name", .string, .required)
            .field("status", .string, .required)
            .field("error_code", .string)
            .field("duration_ms", .int)
            .field("created_at", .datetime)
            .create()

        try await database.schema(PluginInstall.schema)
            .field("marketplace_version_id", .uuid, .references(MarketplaceVersion.schema, "id", onDelete: .setNull))
            .field("granted_permissions", .array(of: .string), .required, .sql(.default("{}")))
            .update()

        let publisher = MarketplacePublisher()
        publisher.id = UUID(uuidString: "00000000-0000-4000-8000-000000000043")!
        // The first-party publisher is system-owned; the bootstrap admin can
        // later claim it in the publisher UI without changing public IDs.
        publisher.ownerUserID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
        publisher.handle = "luminavault"
        publisher.displayName = "LuminaVault"
        publisher.status = "approved"
        publisher.verified = true
        // A system publisher cannot reference a synthetic user through the FK.
        // Seed it only when an admin user exists, otherwise runtime bootstrap
        // creates it lazily.
        if let admin = try await User.query(on: database).filter(\.$isAdmin == true).first() {
            publisher.ownerUserID = try admin.requireID()
            try await publisher.create(on: database)
            for entry in PluginCatalog.entries.values.sorted(by: { $0.dto.slug < $1.dto.slug }) {
                let dto = entry.dto
                let listing = MarketplaceListing()
                listing.id = UUID()
                listing.publisherID = try publisher.requireID()
                listing.slug = dto.slug
                listing.name = dto.name
                listing.summary = dto.summary
                listing.descriptionText = dto.description
                listing.category = dto.category.rawValue
                listing.iconURL = nil
                listing.screenshots = []
                listing.status = "published"
                listing.featured = entry.featured
                try await listing.create(on: database)

                let version = MarketplaceVersion()
                version.id = UUID()
                version.listingID = try listing.requireID()
                version.version = dto.version
                version.status = "approved"
                version.runtimeKind = MarketplaceRuntimeKind.native.rawValue
                version.permissions = []
                version.networkHosts = []
                version.configFields = dto.configFields
                version.publishedAt = Date()
                try await version.create(on: database)
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PluginInstall.schema)
            .deleteField("marketplace_version_id")
            .deleteField("granted_permissions")
            .update()
        try await database.schema(MarketplaceExecution.schema).delete()
        try await database.schema(MarketplaceRating.schema).delete()
        try await database.schema(MarketplaceSubmission.schema).delete()
        try await database.schema(MarketplaceVersion.schema).delete()
        try await database.schema(MarketplaceListing.schema).delete()
        try await database.schema(MarketplacePublisher.schema).delete()
    }
}
