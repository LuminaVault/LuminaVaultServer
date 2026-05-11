import Foundation

/// Anthropic Agent Skills spec-compatible manifest. Parsed from the YAML
/// frontmatter of a `SKILL.md` file shipped either as a built-in resource
/// (`Bundle.module.resourceURL/Resources/Skills/<name>/SKILL.md`) or under
/// a tenant's vault root (`<vaultRoot>/skills/<name>/SKILL.md`).
///
/// Spec-compatible parsing means future skills authored for Claude Code
/// can drop into LuminaVault with no rewrite.
///
/// HER-148 scaffold: type surface only. Parsing logic lands in HER-167.
struct SkillManifest: Codable, Hashable {
    enum Source: String, Codable, Hashable {
        case builtin
        case vault
    }

    enum Capability: String, Codable, Hashable {
        case low
        case medium
        case high
    }

    enum OutputKind: String, Codable, Hashable {
        case memo
        case apnsDigest = "apns_digest"
        case apnsNudge = "apns_nudge"
        case memoryEmit = "memory_emit"
        case vaultRewrite = "vault_rewrite"
    }

    struct Output: Codable, Hashable {
        let kind: OutputKind
        let path: String?
        let category: String?
    }

    /// HER-193 — per-skill daily run cap, declared in the SKILL.md
    /// frontmatter under `metadata.daily_run_cap`. Operators tune by
    /// editing the manifest + redeploying — no migration needed. `0`
    /// means unlimited for that tier.
    ///
    /// Example:
    /// ```yaml
    /// metadata:
    ///   daily_run_cap:
    ///     trial: 3
    ///     pro: 3
    ///     ultimate: 0
    /// ```
    struct DailyRunCap: Codable, Hashable {
        let trial: Int
        let pro: Int
        let ultimate: Int

        /// Cap value for the given tier string (matches `User.tier`:
        /// "trial" / "pro" / "ultimate"). Unknown tiers fall back to the
        /// `trial` value — strictest cap by default.
        func value(for tier: String) -> Int {
            switch tier.lowercased() {
            case "ultimate": ultimate
            case "pro": pro
            case "trial": trial
            default: trial
            }
        }
    }

    let source: Source
    let name: String
    let description: String
    let allowedTools: [String]
    let capability: Capability
    let schedule: String?
    let onEvent: [String]
    let outputs: [Output]
    let dailyRunCap: DailyRunCap?
    let body: String
}

/// Errors surfaced by `SkillManifestParser` when frontmatter is missing,
/// malformed, or violates required-field invariants. Invalid manifests
/// must reject the skill rather than partially load (HER-167 acceptance).
enum SkillManifestError: Error, Equatable {
    case missingFrontmatter
    case malformedFrontmatter(String)
    case missingRequiredField(String)
    case invalidCapability(String)
    case invalidOutputKind(String)
}

/// Parses a `SKILL.md` document into a `SkillManifest`.
///
/// HER-148 scaffold: stub. Real implementation in HER-167 uses Yams to
/// decode the `---`-delimited YAML frontmatter, strips it from the body,
/// and validates required fields.
struct SkillManifestParser {
    init() {}

    func parse(source _: SkillManifest.Source, contents _: String) throws -> SkillManifest {
        throw SkillManifestError.malformedFrontmatter("HER-167 — SkillManifestParser not yet implemented")
    }
}
