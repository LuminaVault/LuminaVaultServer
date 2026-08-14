import Crypto
import Foundation

/// A source-preserving slice of a document.
///
/// The core invariant, asserted by `MarkdownChunkerTests` and relied on by every
/// citation we render: `text` is exactly the source lines `startLine...endLine`
/// (1-based, inclusive) joined by `\n`. That is what lets a hit say "this came
/// from `projects/hermes.md`, under `## Routing`, lines 40-58" and be checkable.
struct DocumentChunk: Sendable, Equatable {
    /// 1-based position within the document, contiguous across the chunk list.
    let ordinal: Int
    /// Heading ancestry of the section this chunk came from, outermost first.
    let headingPath: [String]
    /// 1-based inclusive first source line.
    let startLine: Int
    /// 1-based inclusive last source line.
    let endLine: Int
    /// Exact source text for `startLine...endLine`.
    let text: String
    /// SHA-256 of `text`, lowercase hex.
    let contentSHA256: String
}

/// Deterministic, heading-aware document chunker.
///
/// Same input always produces the same chunks, in the same order, with the same
/// content hashes — which is what makes chunk IDs stable and reindexing a no-op
/// for unchanged content. No LLM, no tokenizer, no embedding service.
///
/// Sections are cut at headings first. A section over `maxChars` is split at
/// paragraph boundaries, and a single oversized paragraph is split at line
/// boundaries. Splits carry `overlapChars` of trailing context forward so a
/// sentence straddling a boundary is still retrievable from one side.
enum MarkdownChunker {
    /// Matches NexusOS's default; ~600 tokens, comfortably inside our embedding window.
    static let defaultMaxChars = 2400
    static let defaultOverlapChars = 200

    /// Chunk a markdown or plain-text document.
    ///
    /// Plain text simply has no headings, so the whole body becomes one section
    /// and takes the same paragraph splitter.
    static func chunk(
        _ source: String,
        maxChars: Int = defaultMaxChars,
        overlapChars: Int = defaultOverlapChars
    ) -> [DocumentChunk] {
        let maxChars = max(1, maxChars)
        let overlapChars = max(0, min(overlapChars, maxChars - 1))

        let lines = source.components(separatedBy: "\n")
        let bodyStart = bodyStartLine(in: lines)
        guard bodyStart <= lines.count else { return [] }

        // Headings are extracted from the body only: a frontmatter block's
        // closing `---` immediately after a `key: value` line would otherwise
        // read as a setext h2.
        let bodyLines = Array(lines[(bodyStart - 1)...])
        let offset = bodyStart - 1
        let headings = MarkdownHeadings.extract(from: bodyLines).map {
            MarkdownHeading(ordinal: $0.ordinal, level: $0.level, text: $0.text, line: $0.line + offset)
        }
        let hierarchy = MarkdownHeadings.hierarchy(for: headings)
        let ordinalByLine = Dictionary(headings.map { ($0.line, $0.ordinal) }, uniquingKeysWith: { first, _ in first })

        var chunks: [DocumentChunk] = []
        for section in sections(lines: lines, bodyStart: bodyStart, ordinalByLine: ordinalByLine, hierarchy: hierarchy) {
            chunks.append(
                contentsOf: split(
                    lines: lines,
                    from: section.start,
                    to: section.end,
                    headingPath: section.headingPath,
                    maxChars: maxChars,
                    overlapChars: overlapChars
                )
            )
        }

        return chunks.enumerated().map { index, chunk in
            DocumentChunk(
                ordinal: index + 1,
                headingPath: chunk.headingPath,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                text: chunk.text,
                contentSHA256: chunk.contentSHA256
            )
        }
    }

    // MARK: - Sectioning

    private struct Section {
        let start: Int
        let end: Int
        let headingPath: [String]
    }

    /// 1-based line where the body begins, skipping a leading YAML frontmatter block.
    private static func bodyStartLine(in lines: [String]) -> Int {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return 1 }
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return index + 2
        }
        // Unterminated frontmatter: treat the whole file as body rather than
        // silently dropping every line.
        return 1
    }

    /// Cut the body into sections, one per heading plus any preamble before the first.
    private static func sections(
        lines: [String],
        bodyStart: Int,
        ordinalByLine: [Int: Int],
        hierarchy: [Int: [String]]
    ) -> [Section] {
        var result: [Section] = []
        var sectionStart = bodyStart
        var currentOrdinal: Int?

        for line in bodyStart...lines.count where ordinalByLine[line] != nil {
            if sectionStart < line {
                result.append(
                    Section(
                        start: sectionStart,
                        end: line - 1,
                        headingPath: currentOrdinal.flatMap { hierarchy[$0] } ?? []
                    )
                )
            }
            sectionStart = line
            currentOrdinal = ordinalByLine[line]
        }

        if sectionStart <= lines.count {
            result.append(
                Section(
                    start: sectionStart,
                    end: lines.count,
                    headingPath: currentOrdinal.flatMap { hierarchy[$0] } ?? []
                )
            )
        }

        return result
    }

    // MARK: - Splitting

    /// Split one section into chunks that each fit `maxChars`.
    private static func split(
        lines: [String],
        from start: Int,
        to end: Int,
        headingPath: [String],
        maxChars: Int,
        overlapChars: Int
    ) -> [DocumentChunk] {
        guard let trimmed = trimBlankEdges(lines: lines, from: start, to: end) else { return [] }

        if sliceLength(lines: lines, from: trimmed.start, to: trimmed.end) <= maxChars {
            return [makeChunk(lines: lines, from: trimmed.start, to: trimmed.end, headingPath: headingPath)]
        }

        var chunks: [DocumentChunk] = []
        var pending: (start: Int, end: Int)?

        for paragraph in paragraphs(lines: lines, from: trimmed.start, to: trimmed.end) {
            if var current = pending {
                if sliceLength(lines: lines, from: current.start, to: paragraph.end) <= maxChars {
                    current.end = paragraph.end
                    pending = current
                    continue
                }
                chunks.append(makeChunk(lines: lines, from: current.start, to: current.end, headingPath: headingPath))
                pending = nil
            }

            // A paragraph that cannot fit on its own is split at line boundaries.
            if sliceLength(lines: lines, from: paragraph.start, to: paragraph.end) > maxChars {
                chunks.append(
                    contentsOf: splitByLines(
                        lines: lines,
                        from: paragraph.start,
                        to: paragraph.end,
                        headingPath: headingPath,
                        maxChars: maxChars,
                        overlapChars: overlapChars
                    )
                )
                continue
            }

            let carried = overlapStart(
                lines: lines,
                before: paragraph.start,
                notBefore: chunks.last.map { $0.startLine + 1 } ?? trimmed.start,
                overlapChars: overlapChars
            )
            pending = (start: carried, end: paragraph.end)
        }

        if let current = pending {
            chunks.append(makeChunk(lines: lines, from: current.start, to: current.end, headingPath: headingPath))
        }

        return chunks
    }

    /// Split an oversized paragraph into line-aligned windows.
    ///
    /// A single line longer than `maxChars` is emitted alone rather than cut:
    /// keeping chunks line-aligned is what preserves the source-slice invariant.
    private static func splitByLines(
        lines: [String],
        from start: Int,
        to end: Int,
        headingPath: [String],
        maxChars: Int,
        overlapChars: Int
    ) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        var windowStart = start
        var cursor = start

        while cursor <= end {
            if cursor > windowStart, sliceLength(lines: lines, from: windowStart, to: cursor) > maxChars {
                chunks.append(makeChunk(lines: lines, from: windowStart, to: cursor - 1, headingPath: headingPath))
                windowStart = overlapStart(
                    lines: lines,
                    before: cursor,
                    notBefore: windowStart + 1,
                    overlapChars: overlapChars
                )
                continue
            }
            cursor += 1
        }

        if windowStart <= end {
            chunks.append(makeChunk(lines: lines, from: windowStart, to: end, headingPath: headingPath))
        }

        return chunks
    }

    /// First line of the trailing window ending at `before - 1` that fits `overlapChars`.
    ///
    /// `notBefore` guarantees forward progress: an overlap can never reopen a
    /// chunk at the same line the previous one started on.
    private static func overlapStart(
        lines: [String],
        before: Int,
        notBefore: Int,
        overlapChars: Int
    ) -> Int {
        guard overlapChars > 0, before > notBefore else { return before }
        var candidate = before
        while candidate > notBefore, sliceLength(lines: lines, from: candidate - 1, to: before - 1) <= overlapChars {
            candidate -= 1
        }
        return candidate
    }

    // MARK: - Line helpers

    /// Contiguous runs of non-blank lines, in order.
    private static func paragraphs(lines: [String], from start: Int, to end: Int) -> [(start: Int, end: Int)] {
        var result: [(start: Int, end: Int)] = []
        var current: Int?

        for line in start...end {
            let isBlank = lines[line - 1].trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if let open = current {
                    result.append((start: open, end: line - 1))
                    current = nil
                }
            } else if current == nil {
                current = line
            }
        }
        if let open = current {
            result.append((start: open, end: end))
        }

        return result
    }

    /// Narrow a range to drop blank leading and trailing lines; nil when all blank.
    private static func trimBlankEdges(lines: [String], from start: Int, to end: Int) -> (start: Int, end: Int)? {
        var first = start
        var last = end
        while first <= last, lines[first - 1].trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }
        while last >= first, lines[last - 1].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
        return first <= last ? (start: first, end: last) : nil
    }

    private static func sliceText(lines: [String], from start: Int, to end: Int) -> String {
        lines[(start - 1)...(end - 1)].joined(separator: "\n")
    }

    private static func sliceLength(lines: [String], from start: Int, to end: Int) -> Int {
        guard start <= end else { return 0 }
        var total = 0
        for line in start...end {
            total += lines[line - 1].count
        }
        // Newlines between the lines.
        return total + (end - start)
    }

    private static func makeChunk(
        lines: [String],
        from start: Int,
        to end: Int,
        headingPath: [String]
    ) -> DocumentChunk {
        let text = sliceText(lines: lines, from: start, to: end)
        return DocumentChunk(
            ordinal: 0,
            headingPath: headingPath,
            startLine: start,
            endLine: end,
            text: text,
            contentSHA256: sha256Hex(text)
        )
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
