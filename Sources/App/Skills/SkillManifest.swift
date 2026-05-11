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
struct SkillManifest: Sendable, Codable, Hashable {
    enum Source: String, Sendable, Codable, Hashable {
        case builtin
        case vault
    }

    enum Capability: String, Sendable, Codable, Hashable {
        case low
        case medium
        case high
    }

    enum OutputKind: String, Sendable, Codable, Hashable {
        case memo
        case apnsDigest = "apns_digest"
        case apnsNudge = "apns_nudge"
        case memoryEmit = "memory_emit"
        case vaultRewrite = "vault_rewrite"
    }

    struct Output: Sendable, Codable, Hashable {
        let kind: OutputKind
        let path: String?
        let category: String?
    }

    let source: Source
    let name: String
    let description: String
    let allowedTools: [String]
    let capability: Capability
    let schedule: String?
    let onEvent: [String]
    let outputs: [Output]
    let body: String
}

/// Errors surfaced by `SkillManifestParser` when frontmatter is missing,
/// malformed, or violates required-field invariants. Invalid manifests
/// must reject the skill rather than partially load (HER-167 acceptance).
enum SkillManifestError: Error, Equatable, Sendable {
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
struct SkillManifestParser: Sendable {
    init() {}

    func parse(source: SkillManifest.Source, contents: String) throws -> SkillManifest {
        throw SkillManifestError.malformedFrontmatter("HER-167 — SkillManifestParser not yet implemented")
    }
}
