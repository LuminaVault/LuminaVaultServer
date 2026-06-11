import FluentKit
import SQLKit

/// HER-43 (Slice 1) — plugin foundation. `plugins` is the first-party catalog
/// (seeded from `PluginCatalog`); `plugin_installs` is the per-tenant install
/// with config sealed at rest (ciphertext + nonce), cascade-deleting with the
/// owning tenant. Unique `(tenant_id, plugin_slug)` enforces one install per
/// plugin per tenant.
struct M62_CreatePlugins: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Plugin.schema)
            .id()
            .field("slug", .string, .required)
            .field("name", .string, .required)
            .field("summary", .string, .required)
            .field("category", .string, .required)
            .field("capability_kind", .string, .required)
            .field("binding", .string, .required)
            .field("icon_slug", .string, .required)
            .field("version", .string, .required)
            .field("publisher", .string, .required)
            .field("verified", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .unique(on: "slug")
            .create()

        try await database.schema(PluginInstall.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("plugin_slug", .string, .required)
            .field("status", .string, .required)
            .field("config_ciphertext", .data, .required)
            .field("config_nonce", .data, .required)
            .field("last_sync_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "plugin_slug")
            .create()

        // Seed the catalog from the static source of truth.
        for entry in PluginCatalog.entries.values {
            let dto = entry.dto
            try await Plugin(
                slug: dto.slug,
                name: dto.name,
                summary: dto.summary,
                category: dto.category.rawValue,
                capabilityKind: dto.capabilityKind.rawValue,
                binding: entry.binding,
                iconSlug: dto.iconSlug,
                version: dto.version,
                publisher: dto.publisher,
                verified: dto.verified
            ).create(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PluginInstall.schema).delete()
        try await database.schema(Plugin.schema).delete()
    }
}
