import FluentKit
import Foundation

/// Seeds the `news-ticker` catalog entry into `plugins`, the way
/// `M62_CreatePlugins` seeded the first five. Idempotent: an existing row
/// (a database that already ran the static seed with this entry present) is
/// left alone.
struct M128_SeedNewsTickerPlugin: AsyncMigration {
    private static let slug = "news-ticker"

    func prepare(on database: any Database) async throws {
        guard let entry = PluginCatalog.entry(slug: Self.slug) else { return }
        if try await Plugin.query(on: database).filter(\.$slug == Self.slug).first() != nil {
            return
        }
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

    func revert(on database: any Database) async throws {
        try await Plugin.query(on: database).filter(\.$slug == Self.slug).delete()
    }
}
