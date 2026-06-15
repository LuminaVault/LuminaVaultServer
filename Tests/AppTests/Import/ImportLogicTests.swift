@testable import App
import Testing

/// Pure-logic unit tests for the "Feed Your Brain" import + compile helpers.
/// No DB / no HTTP, so they run fast and don't hit the AsyncKit teardown
/// SIGILL (HER-310) that the integration suites do.
@Suite("Import logic", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct ImportLogicTests {
    // MARK: - Bookmark HTML parsing

    @Test
    func `parseBookmarksHTML extracts http(s) links, dedupes, drops non-http`() {
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

    @Test
    func `parseBookmarksHTML returns empty for no links`() {
        #expect(ImportService.parseBookmarksHTML("<html><body>no links</body></html>").isEmpty)
    }

    // MARK: - Slugify

    @Test
    func `slugify produces a valid Space slug`() {
        #expect(ImportService.slugify("AI & Machine Learning!") == "ai-machine-learning")
        #expect(ImportService.slugify("  Cooking 101  ") == "cooking-101")
        #expect(ImportService.slugify("***") == "imported") // empty → fallback
        #expect(ImportService.slugify("A").count >= 2) // min length guard
    }

    // MARK: - Categorization mapping parse

    @Test
    func `parseMappings reads the canonical object`() {
        let raw = #"{"mappings":[{"id":"a","space":"ai"},{"id":"b","space":"new:Cooking"}]}"#
        let m = ImportCategorizationService.parseMappings(raw)
        #expect(m["a"] == "ai")
        #expect(m["b"] == "new:Cooking")
    }

    @Test
    func `parseMappings tolerates code fences and surrounding prose`() {
        let fenced = "```json\n{\"mappings\":[{\"id\":\"x\",\"space\":\"health\"}]}\n```"
        #expect(ImportCategorizationService.parseMappings(fenced)["x"] == "health")
        let prose = "Sure! Here is the mapping: {\"mappings\":[{\"id\":\"y\",\"space\":\"imported\"}]} Done."
        #expect(ImportCategorizationService.parseMappings(prose)["y"] == "imported")
    }

    @Test
    func `parseMappings returns empty on garbage`() {
        #expect(ImportCategorizationService.parseMappings("not json").isEmpty)
    }
}

/// Pure-logic tests for the memory-compile extraction parser.
@Suite("Compile extraction parse", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct CompileParseTests {
    @Test
    func `parses canonical {memories:[...]}`() {
        let r = MemoryCompileService.parseExtractedMemories(#"{"memories":["a","b"]}"#)
        #expect(r == ["a", "b"])
    }

    @Test
    func `parses an array of {content} objects`() {
        let r = MemoryCompileService.parseExtractedMemories(#"{"memories":[{"content":"x"},{"content":"y"}]}"#)
        #expect(r == ["x", "y"])
    }

    @Test
    func `parses a bare array`() {
        #expect(MemoryCompileService.parseExtractedMemories(#"["one","two"]"#) == ["one", "two"])
    }

    @Test
    func `strips code fences and prose`() {
        let fenced = "```json\n{\"memories\":[\"z\"]}\n```"
        #expect(MemoryCompileService.parseExtractedMemories(fenced) == ["z"])
        let prose = "Here you go: {\"memories\":[\"p\"]} — that's all."
        #expect(MemoryCompileService.parseExtractedMemories(prose) == ["p"])
    }

    @Test
    func `empty memories yields empty`() {
        #expect(MemoryCompileService.parseExtractedMemories(#"{"memories":[]}"#).isEmpty)
        #expect(MemoryCompileService.parseExtractedMemories("garbage").isEmpty)
    }

    @Test
    func `wikiSlug sanitizes a path basename`() {
        #expect(MemoryCompileService.wikiSlug("captures/2026-05-30-Foo Bar.md") == "2026-05-30-foo-bar")
        #expect(MemoryCompileService.wikiSlug("ai/note.md").isEmpty == false)
    }
}
