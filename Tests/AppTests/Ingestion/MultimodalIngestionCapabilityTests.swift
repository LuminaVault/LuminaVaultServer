@testable import App
import Testing

@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct MultimodalIngestionCapabilityTests {
    @Test("matches exact and wildcard MIME capabilities")
    func matchesMimeCapabilities() {
        #expect(MultimodalIngestionService.supports(contentType: "application/pdf", patterns: ["application/pdf"]))
        #expect(MultimodalIngestionService.supports(contentType: "image/heic", patterns: ["image/*"]))
        #expect(MultimodalIngestionService.supports(contentType: "IMAGE/JPEG", patterns: ["image/*"]))
        #expect(!MultimodalIngestionService.supports(contentType: "video/mp4", patterns: ["image/*", "audio/*"]))
    }

    @Test("BYO ingestion source byte ranges are bounded and support suffixes")
    func sourceRanges() throws {
        #expect(try MultimodalIngestionController.parseRange("bytes=0-99", size: 1000) == 0 ... 99)
        #expect(try MultimodalIngestionController.parseRange("bytes=900-", size: 1000) == 900 ... 999)
        #expect(try MultimodalIngestionController.parseRange("bytes=-100", size: 1000) == 900 ... 999)
        #expect(try MultimodalIngestionController.parseRange("bytes=950-2000", size: 1000) == 950 ... 999)
        #expect(throws: (any Error).self) {
            try MultimodalIngestionController.parseRange("bytes=1000-1001", size: 1000)
        }
        #expect(throws: (any Error).self) {
            try MultimodalIngestionController.parseRange("bytes=0-1,4-5", size: 1000)
        }
    }

    @Test("source tokens are stored as deterministic hashes")
    func hashesSourceTokens() {
        let token = String(repeating: "a", count: 64)
        let hash = MultimodalIngestionService.sourceTokenHash(token)
        #expect(hash.count == 64)
        #expect(hash == MultimodalIngestionService.sourceTokenHash(token))
        #expect(hash != token)
    }
}
