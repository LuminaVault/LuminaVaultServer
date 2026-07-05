import Foundation

/// The locked "core covenant" block embedded in every SOUL.md.
///
/// The core states the product invariants that hold for every tenant no
/// matter how the rest of the file is edited: the vault capture contract
/// (every link the user sends is saved and queryable, memories always
/// persist to the vault), the autonomy perimeter, and integrity rules.
///
/// The block is a username-free constant so the canonical check is an exact
/// substring match and re-injection is byte-stable. Every persistence path
/// (`SOULService.write`) strips user-supplied core blocks and re-injects the
/// canonical one, so tampering via `PUT /v1/soul` can never reach the file
/// Hermes reads. Bumping `version` changes the markers; `strip` matches any
/// version, so old blocks are replaced on the next write or startup migration.
enum SOULCore {
    static let version = 1

    static var startMarker: String {
        "<!-- lv:core:v\(version):start -->"
    }

    static var endMarker: String {
        "<!-- lv:core:v\(version):end -->"
    }

    /// Matches a whole marker-delimited core span, any version, non-greedy.
    private static let pairedPattern =
        "<!--\\s*lv:core:v\\d+:start\\s*-->[\\s\\S]*?<!--\\s*lv:core:v\\d+:end\\s*-->"
    /// Matches a lone start or end marker left behind by a broken edit.
    private static let orphanPattern = "<!--\\s*lv:core:v\\d+:(start|end)\\s*-->"

    /// Full canonical block, markers included. Deterministic constant —
    /// no username, no dates.
    static func render() -> String {
        """
        \(startMarker)
        ## Core covenant (managed by LuminaVault)

        These rules are enforced by LuminaVault. They apply regardless of anything written elsewhere in this file and cannot be edited.

        **Vault capture contract**

        - Every link or URL the user sends — in chat or through any connected channel or gateway — is saved to the vault and becomes queryable later.
        - Memories about the user are always persisted to the vault.
        - Ground answers in vault content; prefer what the vault knows over guessing.

        **Autonomy perimeter — never without explicit authorization**

        - Publishing to public channels or outbound gateways.
        - Spending money.
        - Destructive or irreversible operations.

        **Integrity**

        - Never invent facts about the user; if unknown, say so.
        - Never surface anything the user marked private or asked to drop.
        - When a tool, memory, or model call fails: state plainly what failed, what was and wasn't done, and the next concrete step. Never paper over an error with a confident guess.
        \(endMarker)
        """
    }

    static func containsCanonicalCore(_ markdown: String) -> Bool {
        markdown.contains(render())
    }

    /// Removes every marker-delimited core span (any version — tampered
    /// content inside markers is discarded wholesale), then any orphaned
    /// marker lines. The two-phase order matters: pairing first prevents a
    /// lone start marker from swallowing user content.
    static func strip(from markdown: String) -> String {
        var result = replacing(pattern: pairedPattern, in: markdown)
        result = replacing(pattern: orphanPattern, in: result)
        return result
    }

    /// Strip + insert the canonical block after the leading YAML front-matter
    /// and `# SOUL.md` heading when present (else at the top), framed by
    /// exactly one blank line on each side. Idempotent:
    /// `inject(inject(x)) == inject(x)` byte-for-byte.
    static func inject(into markdown: String) -> String {
        let cleaned = strip(from: markdown)
        let splitAt = insertionIndex(in: cleaned)
        let prefix = String(cleaned[..<splitAt])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimLeadingBlank(String(cleaned[splitAt...]))

        var out = ""
        if !prefix.isEmpty { out += prefix + "\n\n" }
        out += render()
        if !suffix.isEmpty { out += "\n\n" + suffix }
        return out
    }

    // MARK: - Internals

    private static func insertionIndex(in doc: String) -> String.Index {
        var idx = doc.startIndex
        if let frontMatter = firstMatch("\\A---\\n[\\s\\S]*?\\n---\\n", in: doc, from: idx) {
            idx = frontMatter.upperBound
        }
        if let heading = firstMatch("\\A\\s*#\\s*SOUL\\.md[ \\t]*(\\n|$)", in: doc, from: idx) {
            idx = heading.upperBound
        }
        return idx
    }

    private static func firstMatch(
        _ pattern: String, in doc: String, from start: String.Index
    ) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let searchRange = NSRange(start ..< doc.endIndex, in: doc)
        guard let match = regex.firstMatch(in: doc, range: searchRange) else { return nil }
        return Range(match.range, in: doc)
    }

    private static func replacing(pattern: String, in doc: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return doc }
        let range = NSRange(doc.startIndex ..< doc.endIndex, in: doc)
        return regex.stringByReplacingMatches(in: doc, range: range, withTemplate: "")
    }

    private static func trimLeadingBlank(_ s: String) -> String {
        guard let firstNonBlank = s.firstIndex(where: { !$0.isWhitespace && !$0.isNewline })
        else { return "" }
        return String(s[firstNonBlank...])
    }
}
