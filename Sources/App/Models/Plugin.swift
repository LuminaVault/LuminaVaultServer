import FluentKit
import Foundation

/// HER-43 (Slice 1) — a first-party catalog plugin. The authoritative
/// definition (display metadata + config fields) lives in the static
/// `PluginCatalog`; this table is its seeded DB mirror so installs can carry a
/// stable FK and a future marketplace slice has rows to extend. Runtime reads
/// the static catalog (no drift), mirroring `HermesGatewayCatalog`.
///
/// Plugins are declarative: `binding` names the server registry the plugin
/// wires into (e.g. a `ConnectorRegistry` key). No third-party code runs.
final class Plugin: Model, @unchecked Sendable {
    static let schema = "plugins"

    @ID(key: .id) var id: UUID?
    @Field(key: "slug") var slug: String
    @Field(key: "name") var name: String
    @Field(key: "summary") var summary: String
    @Field(key: "category") var category: String
    @Field(key: "capability_kind") var capabilityKind: String
    /// Registry key the capability binds to (e.g. connector binding "readwise").
    @Field(key: "binding") var binding: String
    @Field(key: "icon_slug") var iconSlug: String
    @Field(key: "version") var version: String
    @Field(key: "publisher") var publisher: String
    @Field(key: "verified") var verified: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        slug: String,
        name: String,
        summary: String,
        category: String,
        capabilityKind: String,
        binding: String,
        iconSlug: String,
        version: String,
        publisher: String,
        verified: Bool,
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.summary = summary
        self.category = category
        self.capabilityKind = capabilityKind
        self.binding = binding
        self.iconSlug = iconSlug
        self.version = version
        self.publisher = publisher
        self.verified = verified
    }
}
