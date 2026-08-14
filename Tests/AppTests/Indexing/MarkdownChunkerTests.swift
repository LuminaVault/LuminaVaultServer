@testable import App
import Foundation
import Testing

/// Contract tests for the heading-aware chunker.
///
/// The load-bearing one is `chunk text is exactly the lines it claims`: every
/// citation LuminaVault renders is a promise that `path` + `startLine`-`endLine`
/// point at the text the answer was grounded in. If that invariant breaks, the
/// citations become decoration.
struct MarkdownChunkerTests {
    /// Re-reads the source the way a client following a citation would.
    private func sourceSlice(_ source: String, _ chunk: DocumentChunk) -> String {
        let lines = source.components(separatedBy: "\n")
        return lines[(chunk.startLine - 1)...(chunk.endLine - 1)].joined(separator: "\n")
    }

    private func assertInvariants(_ source: String, _ chunks: [DocumentChunk], sourceLocation: SourceLocation = #_sourceLocation) {
        let lineCount = source.components(separatedBy: "\n").count
        for (index, chunk) in chunks.enumerated() {
            #expect(chunk.ordinal == index + 1, "ordinals must be contiguous from 1", sourceLocation: sourceLocation)
            #expect(chunk.startLine >= 1, sourceLocation: sourceLocation)
            #expect(chunk.endLine >= chunk.startLine, sourceLocation: sourceLocation)
            #expect(chunk.endLine <= lineCount, sourceLocation: sourceLocation)
            #expect(chunk.text == sourceSlice(source, chunk), "chunk text must equal its claimed source slice", sourceLocation: sourceLocation)
            #expect(chunk.contentSHA256 == MarkdownChunker.sha256Hex(chunk.text), sourceLocation: sourceLocation)
        }
    }

    // MARK: - The invariant

    @Test
    func `chunk text is exactly the lines it claims`() {
        let source = """
        # Routing

        Hermes picks a provider per request.

        ## Fallbacks

        When the primary provider errors we retry once, then fall through
        to the secondary.

        ### Timeouts

        Thirty seconds, then abort.
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(!chunks.isEmpty)
        assertInvariants(source, chunks)
    }

    @Test
    func `invariant holds when sections are split`() {
        let paragraph = Array(repeating: "Lorem ipsum dolor sit amet consectetur.", count: 12).joined(separator: " ")
        let source = """
        # Big

        \(paragraph)

        \(paragraph)

        \(paragraph)

        ## Small

        Done.
        """

        let chunks = MarkdownChunker.chunk(source, maxChars: 400, overlapChars: 80)
        #expect(chunks.count > 3, "an oversized section must split")
        assertInvariants(source, chunks)
    }

    @Test
    func `invariant holds for plain text with no headings`() {
        let source = (1...200).map { "line \($0) of an unstructured capture" }.joined(separator: "\n")
        let chunks = MarkdownChunker.chunk(source, maxChars: 300, overlapChars: 50)
        #expect(chunks.count > 1)
        assertInvariants(source, chunks)
    }

    // MARK: - Heading behavior

    @Test
    func `headings cut sections and carry ancestry`() {
        let source = """
        # Top

        intro

        ## Middle

        body

        ### Leaf

        detail

        ## Other

        tail
        """

        let chunks = MarkdownChunker.chunk(source)
        let paths = chunks.map(\.headingPath)
        #expect(paths.contains(["Top"]))
        #expect(paths.contains(["Top", "Middle"]))
        #expect(paths.contains(["Top", "Middle", "Leaf"]))
        #expect(paths.contains(["Top", "Other"]))
        assertInvariants(source, chunks)
    }

    @Test
    func `preamble before the first heading keeps an empty path`() {
        let source = """
        Some notes with no heading yet.

        # Later

        content
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(chunks.first?.headingPath.isEmpty == true)
        assertInvariants(source, chunks)
    }

    @Test
    func `hashes inside fenced code are not headings`() {
        let source = """
        # Real

        ```bash
        # not a heading
        echo hi
        ```

        text
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(chunks.allSatisfy { $0.headingPath == ["Real"] })
        assertInvariants(source, chunks)
    }

    @Test
    func `setext underlines become headings`() {
        let source = """
        Title
        =====

        body

        Subtitle
        --------

        more
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(chunks.map(\.headingPath).contains(["Title"]))
        #expect(chunks.map(\.headingPath).contains(["Title", "Subtitle"]))
        assertInvariants(source, chunks)
    }

    @Test
    func `an ATX heading followed by dashes does not double count`() {
        // `# Foo` then `---` is an ATX heading plus a horizontal rule, not two
        // headings on adjacent lines. NexusOS hit exactly this and resolved it
        // first-wins; we prevent the second match outright.
        let source = """
        # Foo
        ---

        body
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(chunks.allSatisfy { $0.headingPath == ["Foo"] })
        assertInvariants(source, chunks)
    }

    // MARK: - Frontmatter

    @Test
    func `frontmatter is skipped and never read as a heading`() {
        let source = """
        ---
        title: Hermes routing
        tags: [infra]
        ---

        # Routing

        body
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(chunks.allSatisfy { $0.startLine >= 5 }, "no chunk may start inside frontmatter")
        #expect(chunks.allSatisfy { $0.headingPath == ["Routing"] })
        #expect(!chunks.contains { $0.text.contains("title: Hermes routing") })
        assertInvariants(source, chunks)
    }

    @Test
    func `unterminated frontmatter falls back to treating everything as body`() {
        let source = """
        ---
        title: broken

        still content
        """

        let chunks = MarkdownChunker.chunk(source)
        #expect(!chunks.isEmpty, "content must not vanish because the fence never closed")
        assertInvariants(source, chunks)
    }

    // MARK: - Determinism

    @Test
    func `identical input produces identical chunks`() {
        let source = """
        # A

        one

        ## B

        two
        """

        let first = MarkdownChunker.chunk(source)
        let second = MarkdownChunker.chunk(source)
        #expect(first == second)
    }

    @Test
    func `chunk hashes change only when text changes`() {
        let before = MarkdownChunker.chunk("# A\n\nhello")
        let after = MarkdownChunker.chunk("# A\n\nhello there")
        #expect(before.first?.contentSHA256 != after.first?.contentSHA256)
    }

    // MARK: - Edge cases

    @Test
    func `empty and blank documents produce no chunks`() {
        #expect(MarkdownChunker.chunk("").isEmpty)
        #expect(MarkdownChunker.chunk("\n\n   \n\t\n").isEmpty)
    }

    @Test
    func `a single line longer than the cap is emitted whole`() {
        let long = String(repeating: "x", count: 900)
        let chunks = MarkdownChunker.chunk(long, maxChars: 100, overlapChars: 10)
        #expect(chunks.count == 1, "we never cut mid-line; that would break the source-slice invariant")
        #expect(chunks.first?.text == long)
    }

    @Test
    func `splitting always makes forward progress`() {
        // Overlap wider than the content would loop forever if the splitter
        // could reopen a chunk at the line it just started on.
        let source = (1...60).map { "sentence number \($0)." }.joined(separator: "\n")
        let chunks = MarkdownChunker.chunk(source, maxChars: 50, overlapChars: 49)
        #expect(chunks.count > 1)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.startLine > previous.startLine, "each chunk must start later than the last")
        }
        assertInvariants(source, chunks)
    }

    @Test
    func `overlap carries trailing context into the next chunk`() {
        let source = (1...40).map { "paragraph \($0)\n" }.joined(separator: "\n")
        let withOverlap = MarkdownChunker.chunk(source, maxChars: 120, overlapChars: 60)
        let withoutOverlap = MarkdownChunker.chunk(source, maxChars: 120, overlapChars: 0)
        #expect(withOverlap.count >= withoutOverlap.count)
        assertInvariants(source, withOverlap)
        assertInvariants(source, withoutOverlap)
    }
}

/// Stability contract for the two ID kinds.
struct ChunkIDsTests {
    @Test
    func `document id is stable across content changes`() {
        let tenant = UUID()
        let first = ChunkIDs.documentID(tenantID: tenant, path: "projects/hermes.md")
        let second = ChunkIDs.documentID(tenantID: tenant, path: "projects/hermes.md")
        #expect(first == second)
        #expect(first.hasPrefix(ChunkIDs.documentPrefix))
    }

    @Test
    func `document id differs across tenants`() {
        let path = "projects/hermes.md"
        #expect(ChunkIDs.documentID(tenantID: UUID(), path: path) != ChunkIDs.documentID(tenantID: UUID(), path: path))
    }

    @Test
    func `path spellings that mean the same file hash the same`() {
        let tenant = UUID()
        let canonical = ChunkIDs.documentID(tenantID: tenant, path: "projects/hermes.md")
        #expect(ChunkIDs.documentID(tenantID: tenant, path: "./projects/hermes.md") == canonical)
        #expect(ChunkIDs.documentID(tenantID: tenant, path: "/projects/hermes.md") == canonical)
        #expect(ChunkIDs.documentID(tenantID: tenant, path: "projects\\hermes.md") == canonical)
    }

    @Test
    func `chunk id changes when content or position changes`() {
        let doc = ChunkIDs.documentID(tenantID: UUID(), path: "a.md")
        let base = ChunkIDs.chunkID(documentID: doc, ordinal: 1, contentSHA256: "aa")
        #expect(ChunkIDs.chunkID(documentID: doc, ordinal: 1, contentSHA256: "aa") == base)
        #expect(ChunkIDs.chunkID(documentID: doc, ordinal: 2, contentSHA256: "aa") != base)
        #expect(ChunkIDs.chunkID(documentID: doc, ordinal: 1, contentSHA256: "bb") != base)
    }
}
