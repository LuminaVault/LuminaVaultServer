import Foundation

/// Whether a wikilink points at exactly one document.
///
/// `ambiguous` is a first-class outcome, not an error. Two notes named
/// `index.md` in different folders make `[[index]]` genuinely undecidable, and
/// picking one arbitrarily would silently draw a wrong edge on the Brain graph
/// and cite the wrong file. Better to surface it and let the user disambiguate.
enum WikilinkResolutionState: String, Sendable, CaseIterable {
    case resolved
    case unresolved
    case ambiguous
}

/// A candidate link target: one indexed vault file.
struct WikilinkTarget: Sendable, Equatable {
    let vaultFileID: UUID
    /// Vault-relative path, forward slashes, no leading separator.
    let path: String
}

/// A parsed wikilink plus the document it points at.
struct ResolvedWikilink: Sendable, Equatable {
    let link: ParsedWikilink
    /// Nil when `state` is `unresolved` or `ambiguous`.
    let targetVaultFileID: UUID?
    let state: WikilinkResolutionState
}

/// Resolves `[[wikilinks]]` against the set of documents that exist.
///
/// Two tiers, in order, matching how people actually write links:
///
/// 1. **Exact path.** `[[projects/hermes]]` or `[[projects/hermes.md]]` against
///    a stored path, with and without each known suffix.
/// 2. **Unique filename stem.** `[[hermes]]` resolves only if exactly one
///    document is named `hermes.*` anywhere in the vault.
///
/// Anything matching more than one document is `ambiguous` — never guessed.
/// Heading fragments (`[[note#Section]]`) do not participate: they address a
/// place *inside* the target, so they cannot change which document it is.
enum WikilinkResolver {
    /// Extensions stripped when matching. Ordered longest-first so
    /// `.markdown` is tried before `.md` and never leaves a stray `own`.
    static let linkSuffixes = [".markdown", ".md", ".txt"]

    static func resolve(
        links: [ParsedWikilink],
        candidates: [WikilinkTarget]
    ) -> [ResolvedWikilink] {
        guard !links.isEmpty else { return [] }

        var byPath: [String: UUID] = [:]
        var byStem: [String: [UUID]] = [:]
        for candidate in candidates {
            let path = Wikilinks.normalizeSlug(candidate.path)
            byPath[path] = candidate.vaultFileID
            byStem[stem(of: path), default: []].append(candidate.vaultFileID)
        }

        return links.map { link in
            // Tier 1 — exact path, bare and with each suffix.
            if let id = byPath[link.targetSlug] {
                return ResolvedWikilink(link: link, targetVaultFileID: id, state: .resolved)
            }
            for suffix in linkSuffixes {
                if let id = byPath[link.targetSlug + suffix] {
                    return ResolvedWikilink(link: link, targetVaultFileID: id, state: .resolved)
                }
            }

            // Tier 2 — unique filename stem.
            let matches = byStem[stem(of: link.targetSlug)] ?? []
            switch matches.count {
            case 0:
                return ResolvedWikilink(link: link, targetVaultFileID: nil, state: .unresolved)
            case 1:
                return ResolvedWikilink(link: link, targetVaultFileID: matches[0], state: .resolved)
            default:
                return ResolvedWikilink(link: link, targetVaultFileID: nil, state: .ambiguous)
            }
        }
    }

    /// Filename without directories or a known suffix.
    static func stem(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        for suffix in linkSuffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
