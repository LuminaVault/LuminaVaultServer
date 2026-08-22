import Foundation

/// A heading extracted from a markdown source document.
///
/// `line` is 1-based and points at the line carrying the heading text — for a
/// setext heading that is the text line, not the `===` / `---` underline.
struct MarkdownHeading: Sendable, Equatable {
    /// 1-based position in document order.
    let ordinal: Int
    /// ATX depth (1...6). Setext maps `=` to 1 and `-` to 2.
    let level: Int
    /// Heading text with markers and trailing `#` runs stripped.
    let text: String
    /// 1-based line number of the heading text.
    let line: Int
}

/// Deterministic markdown heading extraction.
///
/// Fenced code blocks are skipped so a `# comment` inside a shell snippet is
/// never mistaken for a heading. Two headings can never share a line: when an
/// ATX heading is immediately followed by a setext underline (`# Foo` then
/// `---`), the ATX heading wins and the underline is ignored.
enum MarkdownHeadings {
    private static let atxPrefix = "#"
    private static let maxLevel = 6
    /// ATX headings tolerate up to three leading spaces; four makes it a code block.
    private static let maxIndent = 3

    /// Extract headings from already-split source lines.
    static func extract(from lines: [String]) -> [MarkdownHeading] {
        var headings: [MarkdownHeading] = []
        var fence: String?
        var ordinal = 0
        var previousWasHeading = false

        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open) {
                    fence = nil
                }
                previousWasHeading = false
                continue
            }
            if let opened = fenceMarker(trimmed) {
                fence = opened
                previousWasHeading = false
                continue
            }

            if let level = atxLevel(raw, trimmed: trimmed) {
                ordinal += 1
                headings.append(
                    MarkdownHeading(
                        ordinal: ordinal,
                        level: level,
                        text: atxText(trimmed, level: level),
                        line: lineNumber
                    )
                )
                previousWasHeading = true
                continue
            }

            // Setext: the underline attaches to the PREVIOUS line, which must be
            // non-blank and not already claimed by an ATX heading.
            if let level = setextLevel(trimmed), index > 0, !previousWasHeading {
                let candidate = lines[index - 1].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty {
                    ordinal += 1
                    headings.append(
                        MarkdownHeading(
                            ordinal: ordinal,
                            level: level,
                            text: candidate,
                            line: lineNumber - 1
                        )
                    )
                }
            }
            previousWasHeading = false
        }

        return headings
    }

    /// Map each heading ordinal to its full ancestor path, self last.
    ///
    /// `# A` / `## B` / `### C` yields `["A"]`, `["A", "B"]`, `["A", "B", "C"]`.
    /// A deeper heading with no parent simply starts a shallower path.
    static func hierarchy(for headings: [MarkdownHeading]) -> [Int: [String]] {
        var paths: [Int: [String]] = [:]
        var stack: [(level: Int, text: String)] = []

        for heading in headings {
            while let last = stack.last, last.level >= heading.level {
                stack.removeLast()
            }
            stack.append((level: heading.level, text: heading.text))
            paths[heading.ordinal] = stack.map(\.text)
        }

        return paths
    }

    // MARK: - Line classification

    /// Returns the fence marker (``` or ~~~) when `trimmed` opens a fenced block.
    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return marker
        }
        return nil
    }

    /// ATX level, or nil when the line is not an ATX heading.
    private static func atxLevel(_ raw: String, trimmed: String) -> Int? {
        let indent = raw.prefix { $0 == " " }.count
        guard indent <= maxIndent, trimmed.hasPrefix(atxPrefix) else { return nil }

        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes <= maxLevel else { return nil }

        // `#foo` is not a heading; `#` alone is an empty one.
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return hashes
    }

    private static func atxText(_ trimmed: String, level: Int) -> String {
        var text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
        // Strip a closing run of hashes: `## Title ##` -> `Title`.
        while text.hasSuffix("#") {
            text = String(text.dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Setext level from an underline of `=` (1) or `-` (2), or nil.
    private static func setextLevel(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) {
            return 1
        }
        if trimmed.allSatisfy({ $0 == "-" }) {
            return 2
        }
        return nil
    }
}
