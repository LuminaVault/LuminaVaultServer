import Foundation
import Yams

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
/// Format (Anthropic Agent Skills spec):
/// ```
/// ---
/// name: daily-brief
/// description: Morning brief ...
/// allowed-tools: session_search vault_read
/// metadata:
///   capability: low|medium|high
///   schedule: "0 7 * * *"
///   on_event: [vault_file_created]
///   outputs:
///     - kind: memo
///       path: memos/{date}/daily-brief.md
///       category: ...
///   daily_run_cap:
///     trial: 3
///     pro: 3
///     ultimate: 0
/// ---
/// <body>
/// ```
///
/// `name`, `description`, and `metadata.capability` are required. Anything
/// else is optional. `allowed-tools` accepts either a space-separated
/// string (`"session_search vault_read"`) or a YAML array — the parser
/// normalises both shapes to `[String]`.
///
/// Errors surface descriptive `SkillManifestError` cases — never a partial
/// load. The catalog (`SkillCatalog`, HER-168) logs + skips on any error.
///
/// HER-168: `parseOverride` lets tests inject a synthetic parser without
/// touching the real Yams path. Production callers continue to use
/// `SkillManifestParser()`.
struct SkillManifestParser: Sendable {
    typealias ParseFn = @Sendable (SkillManifest.Source, String) throws -> SkillManifest

    private let parseOverride: ParseFn?

    init(parseOverride: ParseFn? = nil) {
        self.parseOverride = parseOverride
    }

    func parse(source: SkillManifest.Source, contents: String) throws -> SkillManifest {
        if let parseOverride {
            return try parseOverride(source, contents)
        }
        let (frontmatter, body) = try Self.splitFrontmatter(contents)
        let raw: RawManifest
        do {
            raw = try YAMLDecoder().decode(RawManifest.self, from: frontmatter)
        } catch let DecodingError.keyNotFound(key, _) {
            throw SkillManifestError.missingRequiredField(key.stringValue)
        } catch let error as DecodingError {
            throw SkillManifestError.malformedFrontmatter(Self.describe(error))
        } catch {
            throw SkillManifestError.malformedFrontmatter(String(describing: error))
        }
        return try Self.build(source: source, raw: raw, body: body)
    }

    // MARK: - Frontmatter split

    /// Splits the `---`-delimited frontmatter from the body. Both delimiter
    /// lines must equal `---` exactly (no trailing whitespace beyond the
    /// dashes themselves). The leading `---` must be the first non-empty
    /// line of the file so we reject files that ship a leading BOM or
    /// preamble silently.
    private static func splitFrontmatter(_ contents: String) throws -> (frontmatter: String, body: String) {
        let lines = contents.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            throw SkillManifestError.missingFrontmatter
        }
        var endIndex: Int?
        for index in 1 ..< lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }
        }
        guard let endIndex else {
            throw SkillManifestError.malformedFrontmatter("frontmatter has no closing `---` delimiter")
        }
        let frontmatter = lines[1 ..< endIndex].joined(separator: "\n")
        let body = lines.suffix(from: endIndex + 1).joined(separator: "\n")
        return (frontmatter, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Validation + mapping

    private static func build(source: SkillManifest.Source, raw: RawManifest, body: String) throws -> SkillManifest {
        let name = (raw.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SkillManifestError.missingRequiredField("name") }
        let description = (raw.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw SkillManifestError.missingRequiredField("description") }

        let allowedTools = raw.allowedTools?.toArray() ?? []

        guard let capabilityRaw = raw.metadata?.capability else {
            throw SkillManifestError.missingRequiredField("metadata.capability")
        }
        guard let capability = SkillManifest.Capability(rawValue: capabilityRaw) else {
            throw SkillManifestError.invalidCapability(capabilityRaw)
        }

        var outputs: [SkillManifest.Output] = []
        for rawOutput in raw.metadata?.outputs ?? [] {
            guard let kind = SkillManifest.OutputKind(rawValue: rawOutput.kind) else {
                throw SkillManifestError.invalidOutputKind(rawOutput.kind)
            }
            outputs.append(SkillManifest.Output(kind: kind, path: rawOutput.path, category: rawOutput.category))
        }

        let dailyRunCap = raw.metadata?.dailyRunCap.map {
            SkillManifest.DailyRunCap(trial: $0.trial, pro: $0.pro, ultimate: $0.ultimate)
        }

        return SkillManifest(
            source: source,
            name: name,
            description: description,
            allowedTools: allowedTools,
            capability: capability,
            schedule: raw.metadata?.schedule,
            onEvent: raw.metadata?.onEvent ?? [],
            outputs: outputs,
            dailyRunCap: dailyRunCap,
            body: body,
        )
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(_, ctx):
            return "type mismatch at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        case let .dataCorrupted(ctx):
            return "data corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        case let .valueNotFound(_, ctx):
            return "missing value at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        case let .keyNotFound(key, _):
            return "missing key `\(key.stringValue)`"
        @unknown default:
            return String(describing: error)
        }
    }
}

// MARK: - Raw decode shape (private to the parser)

private struct RawManifest: Decodable {
    let name: String?
    let description: String?
    let allowedTools: StringOrArray?
    let metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case allowedTools = "allowed-tools"
        case metadata
    }

    struct Metadata: Decodable {
        let capability: String?
        let schedule: String?
        let onEvent: [String]?
        let outputs: [RawOutput]?
        let dailyRunCap: RawDailyRunCap?

        enum CodingKeys: String, CodingKey {
            case capability
            case schedule
            case onEvent = "on_event"
            case outputs
            case dailyRunCap = "daily_run_cap"
        }
    }

    struct RawOutput: Decodable {
        let kind: String
        let path: String?
        let category: String?
    }

    struct RawDailyRunCap: Decodable {
        let trial: Int
        let pro: Int
        let ultimate: Int
    }
}

/// Frontmatter accepts both `allowed-tools: "session_search vault_read"`
/// (the existing builtin shape) and `allowed-tools: [session_search,
/// vault_read]` (spec-compatible YAML array). Normalised to `[String]`
/// in `toArray()`.
private enum StringOrArray: Decodable {
    case string(String)
    case array([String])

    func toArray() -> [String] {
        switch self {
        case let .string(value):
            return value
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        case let .array(values):
            return values
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String].self) {
            self = .array(value)
            return
        }
        throw DecodingError.typeMismatch(
            StringOrArray.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "expected string or array of strings",
            ),
        )
    }
}
