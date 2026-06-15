@testable import App
import Foundation
import Testing

/// HER-134 — Nomic native dim is 768; we pad to 1536 to fit the column.
/// `padToTarget` is the unit of truth — covering it under test means the
/// HTTP path only has to assert the request body shape.
@Suite("NomicEmbeddingService", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct NomicEmbeddingServiceTests {
    @Test
    func `padToTarget zero-pads short vectors to 1536`() {
        let input = [Float](repeating: 0.7, count: 768)
        let padded = NomicEmbeddingService.padToTarget(input)
        #expect(padded.count == 1536)
        #expect(padded.prefix(768).allSatisfy { $0 == 0.7 })
        #expect(padded.suffix(768).allSatisfy { $0 == 0 })
    }

    @Test
    func `padToTarget passes through exact-length vectors unchanged`() {
        let input = [Float](repeating: 0.1, count: 1536)
        let padded = NomicEmbeddingService.padToTarget(input)
        #expect(padded == input)
    }

    @Test
    func `padToTarget truncates oversize vectors (defensive)`() {
        let input = [Float](repeating: 0.5, count: 2000)
        let padded = NomicEmbeddingService.padToTarget(input)
        #expect(padded.count == 1536)
        #expect(padded.allSatisfy { $0 == 0.5 })
    }
}
