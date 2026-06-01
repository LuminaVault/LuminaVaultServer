import Foundation
import LuminaVaultShared

/// HER-43 (Slice 1) — static, first-party catalog of installable plugins.
/// Authoritative source for display metadata, the registry binding, and the
/// per-install config fields. The `plugins` table is seeded from this list
/// (see `M62_CreatePlugins`); runtime reads the static catalog to avoid drift,
/// exactly like `HermesGatewayCatalog`.
///
/// Slice 1 ships one entry (Readwise connector) to prove the install →
/// configure → sync path end-to-end. Later slices add skill/memory entries.
enum PluginCatalog {
    /// Internal entry: catalog metadata + the registry `binding` key (the DTO
    /// doesn't carry `binding` — it's a server wiring detail, not wire format).
    struct Entry {
        let dto: PluginCatalogEntryDTO
        let binding: String
    }

    static let entries: [String: Entry] = [
        "readwise": Entry(
            dto: PluginCatalogEntryDTO(
                slug: "readwise",
                name: "Readwise",
                summary: "Import your Readwise highlights' source articles into your vault.",
                description: """
                Pulls the source articles behind your Readwise highlights and \
                stages them into your Imported inbox, where Smart Import files \
                them into Spaces and compiles them into memories. Provide a \
                Readwise access token (readwise.io/access_token).
                """,
                category: .connector,
                capabilityKind: .connector,
                iconSlug: "readwise",
                version: "1.0.0",
                publisher: "LuminaVault",
                verified: true,
                configFields: [
                    PluginConfigField(
                        key: "access_token",
                        label: "Access token",
                        placeholder: "readwise.io/access_token",
                        kind: .secret,
                        isRequired: true,
                    ),
                ],
            ),
            binding: "readwise",
        ),
        "rss": Entry(
            dto: PluginCatalogEntryDTO(
                slug: "rss",
                name: "RSS / Atom feed",
                summary: "Pull new articles from any RSS or Atom feed into your vault.",
                description: """
                Fetches a feed you paste and stages each item's article into your \
                Imported inbox, where Smart Import files them into Spaces and \
                compiles them into memories. Works with any public RSS or Atom URL.
                """,
                category: .connector,
                capabilityKind: .connector,
                iconSlug: "rss",
                version: "1.0.0",
                publisher: "LuminaVault",
                verified: true,
                configFields: [
                    PluginConfigField(
                        key: "feed_url",
                        label: "Feed URL",
                        placeholder: "https://example.com/feed.xml",
                        kind: .url,
                        isRequired: true,
                    ),
                ],
            ),
            binding: "rss",
        ),
        "raindrop": Entry(
            dto: PluginCatalogEntryDTO(
                slug: "raindrop",
                name: "Raindrop.io",
                summary: "Import your Raindrop.io bookmarks into your vault.",
                description: """
                Pulls your saved Raindrop.io bookmarks and stages each link into \
                your Imported inbox, where Smart Import files them into Spaces and \
                compiles them into memories. Provide a Raindrop test token \
                (app.raindrop.io → Settings → Integrations).
                """,
                category: .connector,
                capabilityKind: .connector,
                iconSlug: "raindrop",
                version: "1.0.0",
                publisher: "LuminaVault",
                verified: true,
                configFields: [
                    PluginConfigField(
                        key: "access_token",
                        label: "Access token",
                        placeholder: "test token from raindrop.io integrations",
                        kind: .secret,
                        isRequired: true,
                    ),
                ],
            ),
            binding: "raindrop",
        ),
        "byok-embeddings": Entry(
            dto: PluginCatalogEntryDTO(
                slug: "byok-embeddings",
                name: "Your own embeddings key",
                summary: "Use your own API key for memory embeddings (same model — no re-embedding).",
                description: """
                Routes this workspace's embedding requests through your own \
                provider API key instead of the shared one. It uses the same \
                embedding model the platform already uses, so your existing \
                memories stay searchable — no re-embedding. Provide the API key \
                for the active embedding provider (OpenAI or Nomic).
                """,
                category: .memory,
                capabilityKind: .memory,
                iconSlug: "memory",
                version: "1.0.0",
                publisher: "LuminaVault",
                verified: true,
                configFields: [
                    PluginConfigField(
                        key: "access_token",
                        label: "Embedding API key",
                        placeholder: "sk-… (OpenAI) or nomic key",
                        kind: .secret,
                        isRequired: true,
                    ),
                ],
            ),
            binding: "byok-embeddings",
        ),
    ]

    static func entry(slug: String) -> Entry? {
        entries[slug]
    }

    /// All catalog DTOs, optionally filtered by category. Stable ordering by
    /// slug so the client list is deterministic.
    static func catalog(category: PluginCategory? = nil) -> [PluginCatalogEntryDTO] {
        entries.values
            .map(\.dto)
            .filter { category == nil || $0.category == category }
            .sorted { $0.slug < $1.slug }
    }

    /// Validate a config dict against the entry's fields: every required field
    /// must be present and non-empty; unknown keys are rejected. Returns the
    /// offending key for stable error codes.
    static func validate(slug: String, config: [String: String]) -> ValidationResult {
        guard let entry = entries[slug] else { return .unknownPlugin }
        let allowed = Set(entry.dto.configFields.map(\.key))
        for key in config.keys where !allowed.contains(key) {
            return .unknownField(key)
        }
        for field in entry.dto.configFields where field.isRequired {
            let value = config[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == nil || value!.isEmpty {
                return .missing(field.key)
            }
        }
        return .ok
    }

    enum ValidationResult: Equatable {
        case ok
        case unknownPlugin
        case missing(String)
        case unknownField(String)
    }
}
