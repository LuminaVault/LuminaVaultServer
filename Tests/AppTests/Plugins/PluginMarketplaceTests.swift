@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// HER-43 Slice 6 — marketplace curation (featured/premium) + premium gating.
/// Pure-logic (no DB / no HTTP), avoiding the AsyncKit teardown SIGILL (HER-310).
@Suite("Plugin marketplace curation")
struct PluginMarketplaceTests {
    @Test
    func `readwise is featured, byok-embeddings is premium`() {
        #expect(PluginCatalog.entry(slug: "readwise")?.featured == true)
        #expect(PluginCatalog.isPremium(slug: "byok-embeddings") == true)
        #expect(PluginCatalog.isPremium(slug: "readwise") == false)
        // Skill/Hermes pseudo-slugs aren't in the static catalog.
        #expect(PluginCatalog.isPremium(slug: "skill-pattern-detector") == false)
    }

    @Test
    func `featured and premium filters select the right entries`() {
        #expect(PluginCatalog.catalog(featured: true).map(\.slug) == ["readwise"])
        #expect(PluginCatalog.catalog(premium: true).map(\.slug) == ["byok-embeddings"])
        // Category + curation compose.
        #expect(PluginCatalog.catalog(category: .connector, featured: true).map(\.slug) == ["readwise"])
        #expect(PluginCatalog.catalog(category: .memory, premium: false).isEmpty)
        // Unfiltered still returns all static entries.
        #expect(PluginCatalog.catalog().map(\.slug) == ["byok-embeddings", "raindrop", "reading-time", "readwise", "rss"])
    }
}
