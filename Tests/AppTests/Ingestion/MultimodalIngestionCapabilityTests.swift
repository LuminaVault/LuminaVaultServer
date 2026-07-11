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

    @Test("source tokens are stored as deterministic hashes")
    func hashesSourceTokens() {
        let token = String(repeating: "a", count: 64)
        let hash = MultimodalIngestionService.sourceTokenHash(token)
        #expect(hash.count == 64)
        #expect(hash == MultimodalIngestionService.sourceTokenHash(token))
        #expect(hash != token)
    }
}
