@testable import App
import Testing

struct KnowledgeExtractionWorkerTests {
    @Test("Extraction keeps meaningful statements and skips fragments")
    func statementSegmentation() {
        let values = KnowledgeExtractionWorker.statements(
            from: "Tiny. LuminaVault connects Project Atlas to planning. It also records decisions!"
        )
        #expect(values == [
            "LuminaVault connects Project Atlas to planning",
            "It also records decisions",
        ])
    }

    @Test("Entity extraction is canonical and de-duplicated")
    func entityExtraction() {
        let values = KnowledgeExtractionWorker.entities(
            in: "Project Atlas depends on LuminaVault, while Project Atlas informs Hermes Agent"
        )
        #expect(values.contains("Project Atlas"))
        #expect(values.contains("LuminaVault"))
        #expect(values.contains("Hermes Agent"))
        #expect(values.filter { $0 == "Project Atlas" }.count == 1)
    }

    @Test(
        "Polarity markers are detected without treating ordinary claims as negative",
        arguments: [
            ("I will not ship this", true),
            ("Hermes never stores secrets", true),
            ("LuminaVault stores evidence", false),
        ]
    )
    func polarity(value: (String, Bool)) {
        #expect(KnowledgeExtractionWorker.isNegative(value.0) == value.1)
    }

    @Test("Event detection recognizes temporal language and years")
    func eventDetection() {
        #expect(KnowledgeExtractionWorker.looksLikeEvent("Project Atlas launched in 2026"))
        #expect(KnowledgeExtractionWorker.looksLikeEvent("After the review, the plan changed"))
        #expect(KnowledgeExtractionWorker.looksLikeEvent("LuminaVault stores claims") == false)
    }

    @Test("Explicit causal and temporal language produces directed relations")
    func explicitRelations() throws {
        let because = try #require(KnowledgeExtractionWorker.explicitRelation(in: "The plan changed because the review found a risk"))
        #expect(because.from == "the review found a risk")
        #expect(because.to == "The plan changed")
        #expect(because.predicate == "causes")

        let after = try #require(KnowledgeExtractionWorker.explicitRelation(in: "After the review, the plan changed"))
        #expect(after.from == "the review")
        #expect(after.to == "the plan changed")
        #expect(after.predicate == "precedes")
    }

    @Test("Fingerprints are stable and content-sensitive")
    func fingerprints() {
        let first = KnowledgeExtractionWorker.fingerprint("claim")
        #expect(first == KnowledgeExtractionWorker.fingerprint("claim"))
        #expect(first != KnowledgeExtractionWorker.fingerprint("different claim"))
        #expect(first.count == 64)
    }
}
