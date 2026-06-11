import Foundation
import LuminaVaultShared

/// HER-43 (Slice 3a) — bridges the existing skills subsystem into the plugin
/// catalog. LV's predefined skills (filesystem `SKILL.md` manifests loaded by
/// `SkillCatalog`) surface as `.skill` plugin entries; installing one flips
/// `SkillsState.enabled` so the existing `SkillRunner` + `/v1/skills` dashboard
/// keep running it (we extend, we don't unify). Skills carry no install config.
///
/// Slug scheme: LV predefined skills are `skill-<manifest.name>`; Hermes-hub
/// installed skills (read-only mirror of the tenant's Hermes `GET /v1/skills`)
/// are `hermes-<name>`. The prefixes keep skill slugs from colliding with
/// connector slugs (`readwise`, `rss`, …) and let `PluginService` route an
/// install to the right backend.
enum SkillPluginCatalog {
    static let lvPrefix = "skill-"
    static let hermesPrefix = "hermes-"

    /// Recover an LV predefined skill's manifest name from a plugin slug, or
    /// nil if the slug isn't an LV skill slug.
    static func lvSkillName(fromSlug slug: String) -> String? {
        guard slug.hasPrefix(lvPrefix) else { return nil }
        let name = String(slug.dropFirst(lvPrefix.count))
        return name.isEmpty ? nil : name
    }

    /// Catalog entry for an LV predefined skill manifest.
    static func entry(forSkillName name: String, description: String) -> PluginCatalogEntryDTO {
        PluginCatalogEntryDTO(
            slug: lvPrefix + name,
            name: titleize(name),
            summary: summarize(description),
            description: description,
            category: .skill,
            capabilityKind: .skill,
            iconSlug: "skill",
            version: "1.0.0",
            publisher: "LuminaVault",
            verified: true,
            configFields: []
        )
    }

    /// Read-only catalog entry for a skill already installed in the tenant's
    /// Hermes agent. Not installable from LV in Slice 3a (hub install lands in
    /// Slice 3b); `publisher: "Hermes"` lets the client render it distinctly.
    static func hermesEntry(name: String, description: String?) -> PluginCatalogEntryDTO {
        PluginCatalogEntryDTO(
            slug: hermesPrefix + name,
            name: titleize(name),
            summary: summarize(description ?? "Installed in your Hermes agent."),
            description: description ?? "Installed in your Hermes agent.",
            category: .skill,
            capabilityKind: .skill,
            iconSlug: "hermes",
            version: "1.0.0",
            publisher: "Hermes",
            verified: true,
            configFields: []
        )
    }

    /// Tolerant decode of a Hermes `GET /v1/skills` body into catalog entries.
    /// Hermes' exact shape isn't contract-frozen, so accept the common forms:
    /// `{"skills":[…]}`, `{"data":[…]}`, or a bare `[…]`; each element may be a
    /// string name or an object with `name`/`id` + optional `description`.
    static func parseHermesSkills(_ data: Data) -> [PluginCatalogEntryDTO] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawList: [Any] = if let arr = json as? [Any] {
            arr
        } else if let obj = json as? [String: Any] {
            (obj["skills"] as? [Any]) ?? (obj["data"] as? [Any]) ?? (obj["items"] as? [Any]) ?? []
        } else {
            []
        }

        var entries: [PluginCatalogEntryDTO] = []
        var seen = Set<String>()
        for item in rawList {
            let name: String?
            var description: String?
            if let s = item as? String {
                name = s
            } else if let o = item as? [String: Any] {
                name = (o["name"] as? String) ?? (o["id"] as? String)
                description = o["description"] as? String
            } else {
                name = nil
            }
            guard let name, !name.isEmpty, seen.insert(name).inserted else { continue }
            entries.append(hermesEntry(name: name, description: description))
        }
        return entries.sorted { $0.slug < $1.slug }
    }

    // MARK: - Display helpers

    /// "pattern-detector" → "Pattern Detector".
    static func titleize(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// First line / sentence, capped, for the catalog row subtitle.
    static func summarize(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 140 ? trimmed : String(trimmed.prefix(139)) + "…"
    }
}
