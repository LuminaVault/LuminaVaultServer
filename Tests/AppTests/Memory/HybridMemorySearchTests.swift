@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Merge semantics for the two retrieval arms.
///
/// The rule that matters: a memory found by both arms must appear once, as the
/// chunk hit, because only the chunk hit carries the line range a user can
/// check. Getting this wrong shows up as duplicated sources in the UI and
/// duplicated context in the prompt.
struct HybridMemorySearchTests {
    private func chunkHit(_ id: UUID, path: String, startLine: Int = 1) -> MemorySearchResult {
        MemorySearchResult(
            id: id,
            tenantID: UUID(),
            content: "chunk text",
            createdAt: nil,
            distance: 0.2,
            citation: MemoryCitation(
                chunkID: "lv_chk_\(String(repeating: "a", count: 32))",
                documentID: "lv_doc_\(String(repeating: "b", count: 32))",
                path: path,
                headingPath: ["Routing"],
                startLine: startLine,
                endLine: startLine + 4
            )
        )
    }

    private func documentHit(_ id: UUID) -> MemorySearchResult {
        MemorySearchResult(
            id: id,
            tenantID: UUID(),
            content: "whole document text",
            createdAt: nil,
            distance: 0.3
        )
    }

    @Test
    func `a memory found by both arms appears once, as the chunk hit`() {
        let shared = UUID()
        let merged = HybridMemorySearch.merge(
            chunks: [chunkHit(shared, path: "projects/hermes.md")],
            documents: [documentHit(shared)],
            limit: 10
        )
        #expect(merged.count == 1)
        #expect(merged[0].citation?.path == "projects/hermes.md")
    }

    @Test
    func `document hits fill remaining slots`() {
        let a = UUID()
        let b = UUID()
        let merged = HybridMemorySearch.merge(
            chunks: [chunkHit(a, path: "a.md")],
            documents: [documentHit(b)],
            limit: 10
        )
        #expect(merged.count == 2)
        #expect(merged[0].id == a, "chunk hits keep their fused order and come first")
        #expect(merged[1].citation == nil)
    }

    @Test
    func `limit is respected across both arms`() {
        let chunks = (0 ..< 5).map { chunkHit(UUID(), path: "c\($0).md") }
        let documents = (0 ..< 5).map { _ in documentHit(UUID()) }
        let merged = HybridMemorySearch.merge(chunks: chunks, documents: documents, limit: 3)
        #expect(merged.count == 3)
        #expect(merged.allSatisfy { $0.citation != nil }, "chunk hits fill the budget first")
    }

    @Test
    func `an empty chunk arm degrades to today's document-only behavior`() {
        // This is the failure mode that must stay boring: chunk indexing broke,
        // backfill has not run, or the tenant is brand new.
        let documents = (0 ..< 3).map { _ in documentHit(UUID()) }
        let merged = HybridMemorySearch.merge(chunks: [], documents: documents, limit: 5)
        #expect(merged.count == 3)
        #expect(merged.allSatisfy { $0.citation == nil })
    }

    @Test
    func `duplicates within one arm are collapsed`() {
        let id = UUID()
        let merged = HybridMemorySearch.merge(
            chunks: [chunkHit(id, path: "a.md", startLine: 1), chunkHit(id, path: "a.md", startLine: 40)],
            documents: [],
            limit: 10
        )
        #expect(merged.count == 1, "one memory is one source, however many of its chunks matched")
    }
}

/// The citation trail rendered into prompts and source chips.
struct MemoryCitationTrailTests {
    @Test
    func `trail joins path, headings, and line range`() {
        let citation = MemoryCitation(
            chunkID: "c", documentID: "d",
            path: "projects/hermes.md",
            headingPath: ["Routing", "Fallbacks"],
            startLine: 40, endLine: 58
        )
        #expect(citation.displayTrail == "projects/hermes.md › Routing › Fallbacks (L40-58)")
    }

    @Test
    func `a single-line chunk reads as one line, not a range`() {
        let citation = MemoryCitation(
            chunkID: "c", documentID: "d", path: "a.md", headingPath: [], startLine: 7, endLine: 7
        )
        #expect(citation.displayTrail == "a.md (L7)")
    }

    @Test
    func `a chunk with no source file still cites its lines`() {
        let citation = MemoryCitation(
            chunkID: "c", documentID: "d", path: nil, headingPath: [], startLine: 1, endLine: 3
        )
        #expect(citation.displayTrail == "L1-3")
    }
}

/// Grounding-prompt shape.
struct QueryPromptCitationTests {
    @Test
    func `prompt carries the source locator for chunk-backed hits`() {
        let hit = MemorySearchResult(
            id: UUID(),
            tenantID: UUID(),
            content: "We retry once, then fall through to the secondary.",
            createdAt: nil,
            distance: 0.1,
            citation: MemoryCitation(
                chunkID: "c", documentID: "d",
                path: "projects/hermes.md",
                headingPath: ["Routing"],
                startLine: 40, endLine: 58
            )
        )
        let messages = QueryController.buildPrompt(query: "how do fallbacks work?", hits: [hit])
        let system = messages.first { $0.role == "system" }?.content ?? ""
        #expect(system.contains("projects/hermes.md › Routing (L40-58)"))
        #expect(system.contains("[1]"), "bracket numbering still lines up with the source events")
    }

    @Test
    func `a hit with no citation renders without a locator bracket`() {
        let hit = MemorySearchResult(
            id: UUID(), tenantID: UUID(), content: "legacy memory", createdAt: nil, distance: 0.1
        )
        let messages = QueryController.buildPrompt(query: "q", hits: [hit])
        let system = messages.first { $0.role == "system" }?.content ?? ""
        #expect(system.contains("legacy memory"))
        #expect(!system.contains("(L"), "no line range may be invented for a hit that has none")
    }

    @Test
    func `no hits still produces a grounded prompt`() {
        let messages = QueryController.buildPrompt(query: "q", hits: [])
        let system = messages.first { $0.role == "system" }?.content ?? ""
        #expect(system.contains("no relevant memories were found"))
    }
}
