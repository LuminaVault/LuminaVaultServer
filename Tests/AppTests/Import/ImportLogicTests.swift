import Testing
@testable import App

/// Pure-logic unit tests for the "Feed Your Brain" import + compile helpers.
/// No DB / no HTTP, so they run fast and don't hit the AsyncKit teardown
/// SIGILL (HER-310) that the integration suites do.
@Suite("Import logic")
struct ImportLogicTests {
    // MARK: - Bookmark HTML parsing

    @Test("parseBookmarksHTML extracts http(s) links, dedupes, drops non-http")
    func parseBookmarks() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><A HREF="https://news.ycombinator.com/">HN</A>
          <DT><A HREF="http://example.com/a">A</A>
          <DT><A HREF="not-a-url">bad</A>
          <DT><A HREF="javascript:void(0)">js</A>
          <DT><A HREF="https://news.ycombinator.com/">HN dup</A>
        </DL><p>
        """
        let urls = ImportService.parseBookmarksHTML(html)
        #expect(urls == ["https://news.ycombinator.com/", "http://example.com/a"])
    }

    @Test("parseBookmarksHTML returns empty for no links")
    func parseBookmarksEmpty() {
        #expect(ImportService.parseBookmarksHTML("<html><body>no links</body></html>").isEmpty)
    }

    // MARK: - Slugify

    @Test("slugify produces a valid Space slug")
    func slugify() {
        #expect(ImportService.slugify("AI & Machine Learning!") == "ai-machine-learning")
        #expect(ImportService.slugify("  Cooking 101  ") == "cooking-101")
        #expect(ImportService.slugify("***") == "imported") // empty → fallback
        #expect(ImportService.slugify("A").count >= 2)       // min length guard
    }

    // MARK: - Categorization mapping parse

    @Test("parseMappings reads the canonical object")
    func mappings() {
        let raw = #"{"mappings":[{"id":"a","space":"ai"},{"id":"b","space":"new:Cooking"}]}"#
        let m = ImportCategorizationService.parseMappings(raw)
        #expect(m["a"] == "ai")
        #expect(m["b"] == "new:Cooking")
    }

    @Test("parseMappings tolerates code fences and surrounding prose")
    func mappingsLenient() {
        let fenced = "```json\n{\"mappings\":[{\"id\":\"x\",\"space\":\"health\"}]}\n```"
        #expect(ImportCategorizationService.parseMappings(fenced)["x"] == "health")
        let prose = "Sure! Here is the mapping: {\"mappings\":[{\"id\":\"y\",\"space\":\"imported\"}]} Done."
        #expect(ImportCategorizationService.parseMappings(prose)["y"] == "imported")
    }

    @Test("parseMappings returns empty on garbage")
    func mappingsGarbage() {
        #expect(ImportCategorizationService.parseMappings("not json").isEmpty)
    }
}

/// Pure-logic tests for the memory-compile extraction parser.
@Suite("Compile extraction parse")
struct CompileParseTests {
    @Test("parses canonical {memories:[...]}")
    func object() {
        let r = MemoryCompileService.parseExtractedMemories(#"{"memories":["a","b"]}"#)
        #expect(r == ["a", "b"])
    }

    @Test("parses an array of {content} objects")
    func arrayOfObjects() {
        let r = MemoryCompileService.parseExtractedMemories(#"{"memories":[{"content":"x"},{"content":"y"}]}"#)
        #expect(r == ["x", "y"])
    }

    @Test("parses a bare array")
    func bareArray() {
        #expect(MemoryCompileService.parseExtractedMemories(#"["one","two"]"#) == ["one", "two"])
    }

    @Test("strips code fences and prose")
    func fencedAndProse() {
        let fenced = "```json\n{\"memories\":[\"z\"]}\n```"
        #expect(MemoryCompileService.parseExtractedMemories(fenced) == ["z"])
        let prose = "Here you go: {\"memories\":[\"p\"]} — that's all."
        #expect(MemoryCompileService.parseExtractedMemories(prose) == ["p"])
    }

    @Test("empty memories yields empty")
    func empty() {
        #expect(MemoryCompileService.parseExtractedMemories(#"{"memories":[]}"#).isEmpty)
        #expect(MemoryCompileService.parseExtractedMemories("garbage").isEmpty)
    }

    @Test("wikiSlug sanitizes a path basename")
    func wikiSlug() {
        #expect(MemoryCompileService.wikiSlug("captures/2026-05-30-Foo Bar.md") == "2026-05-30-foo-bar")
        #expect(MemoryCompileService.wikiSlug("ai/note.md").isEmpty == false)
    }
}
