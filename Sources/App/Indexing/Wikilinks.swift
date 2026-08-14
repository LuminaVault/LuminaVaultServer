import Foundation

/// A `[[wikilink]]` as written in a document, before resolution.
///
/// Obsidian's syntax, which is what users' vaults actually contain:
///
///     [[note]]                    target only
///     [[folder/note]]             path target
///     [[note|Label]]              aliased
///     [[note#Heading]]            heading fragment
///     [[note#Heading|Label]]      both
struct ParsedWikilink: Sendable, Equatable {
    /// 1-based line the link appears on.
    let line: Int
    /// Everything between the brackets, verbatim — kept so an unresolved link
    /// can be reported back to the user exactly as they typed it.
    let rawTarget: String
    /// Target with alias and heading stripped, normalized to forward slashes.
    let targetSlug: String
    /// Heading fragment after `#`, or nil.
    let targetHeading: String?
    /// Display alias after `|`, or nil.
    let label: String?
}

/// Extracts `[[wikilinks]]` from markdown.
///
/// LuminaVault has always *stored* wikilinks — they ride inside the markdown
/// body — but never parsed them server-side. `MemoryGraphService`'s `.wikilink`
/// edge kind is actually a foreign key to the source file, not a real link. So
/// the Brain graph has never shown what the user actually wrote, and backlinks
/// have never existed. This is the parser that fixes that.
///
/// Deliberately conservative about where a link can appear: fenced code blocks
/// and inline code spans are skipped, because `[[not a link]]` inside a shell
/// snippet is documentation, not a graph edge.
enum Wikilinks {
    /// Longest target we will accept. Anything beyond this is malformed input,
    /// not a link, and we refuse to build an index row for it.
    static let maxTargetLength = 512

    /// Extract every wikilink from already-split source lines.
    static func extract(from lines: [String]) -> [ParsedWikilink] {
        var links: [ParsedWikilink] = []
        var fence: String?

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if let opened = fenceMarker(trimmed) {
                fence = opened
                continue
            }

            links.append(contentsOf: extractLine(raw, line: index + 1))
        }
        return links
    }

    static func extract(from source: String) -> [ParsedWikilink] {
        extract(from: source.components(separatedBy: "\n"))
    }

    // MARK: - Line scanning

    /// Scan one line for `[[...]]`, skipping inline code spans.
    ///
    /// Hand-rolled rather than a regex because we need to track backtick state
    /// across the line and reject unterminated brackets without backtracking.
    private static func extractLine(_ raw: String, line: Int) -> [ParsedWikilink] {
        var results: [ParsedWikilink] = []
        let characters = Array(raw)
        var index = 0
        var inCode = false

        while index < characters.count {
            if characters[index] == "`" {
                inCode.toggle()
                index += 1
                continue
            }
            guard !inCode,
                  characters[index] == "[",
                  index + 1 < characters.count,
                  characters[index + 1] == "["
            else {
                index += 1
                continue
            }

            guard let close = closingIndex(characters, from: index + 2) else {
                // Unterminated `[[` — no further link can start on this line.
                break
            }
            let inner = String(characters[(index + 2) ..< close])
            if let link = parse(inner, line: line) {
                results.append(link)
            }
            index = close + 2
        }
        return results
    }

    /// Index of the `]]` that closes a link opened before `start`, or nil.
    private static func closingIndex(_ characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + 1 < characters.count {
            if characters[index] == "]", characters[index + 1] == "]" {
                return index
            }
            // A nested `[[` means the outer one was never a link.
            if characters[index] == "[", characters[index + 1] == "[" {
                return nil
            }
            index += 1
        }
        return nil
    }

    // MARK: - Target parsing

    /// Split `folder/note#Heading|Label` into its parts. Nil when the target is
    /// empty or implausibly long.
    static func parse(_ inner: String, line: Int) -> ParsedWikilink? {
        let raw = inner.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.count <= maxTargetLength else { return nil }

        // Alias first: a `|` always separates target from display text, and a
        // heading fragment belongs to the target side.
        var targetPart = raw
        var label: String?
        if let pipe = raw.firstIndex(of: "|") {
            targetPart = String(raw[raw.startIndex ..< pipe]).trimmingCharacters(in: .whitespaces)
            let aliasText = String(raw[raw.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            label = aliasText.isEmpty ? nil : aliasText
        }

        var heading: String?
        if let hash = targetPart.firstIndex(of: "#") {
            let headingText = String(targetPart[targetPart.index(after: hash)...])
                .trimmingCharacters(in: .whitespaces)
            heading = headingText.isEmpty ? nil : headingText
            targetPart = String(targetPart[targetPart.startIndex ..< hash])
                .trimmingCharacters(in: .whitespaces)
        }

        // `[[#Heading]]` is a same-document anchor, not an edge between notes.
        guard !targetPart.isEmpty else { return nil }

        return ParsedWikilink(
            line: line,
            rawTarget: raw,
            targetSlug: normalizeSlug(targetPart),
            targetHeading: heading,
            label: label
        )
    }

    /// Forward-slash form, no leading `./` or `/`, case preserved.
    ///
    /// Case is preserved because resolution compares against real stored paths;
    /// lowercasing here would silently merge `Notes/A.md` and `notes/a.md` into
    /// one edge on a case-sensitive filesystem.
    static func normalizeSlug(_ target: String) -> String {
        var slug = target.replacingOccurrences(of: "\\", with: "/")
        while slug.hasPrefix("./") { slug = String(slug.dropFirst(2)) }
        while slug.hasPrefix("/") { slug = String(slug.dropFirst()) }
        while slug.hasSuffix("/") { slug = String(slug.dropLast()) }
        return slug
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return marker
        }
        return nil
    }
}
