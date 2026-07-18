@testable import App
import Foundation
import Testing

/// Pure unit tests for the retrieval-telemetry sample derivation — no DB.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct RetrievalTelemetrySampleTests {
    @Test
    func `from computes min top and mean over distances`() {
        let s = RetrievalTelemetrySample.from(
            tenantID: UUID(),
            distances: [0.4, 0.1, 0.3],
            source: .localReply,
            spaceID: nil,
            limit: 5
        )
        #expect(s.hitCount == 3)
        // Distances widen from Float, so compare with a tolerance.
        #expect(abs((s.topDistance ?? -1) - 0.1) < 1e-6)
        #expect(abs((s.meanDistance ?? -1) - (0.8 / 3.0)) < 1e-6)
        #expect(s.sourcePath == .localReply)
        #expect(s.limitRequested == 5)
    }

    @Test
    func `empty hits are zero-hit with nil distances`() {
        let s = RetrievalTelemetrySample.from(
            tenantID: UUID(),
            distances: [],
            source: .query,
            spaceID: nil,
            limit: 5
        )
        #expect(s.hitCount == 0)
        #expect(s.topDistance == nil)
        #expect(s.meanDistance == nil)
        // The model derives zeroHit from hitCount.
        #expect(RetrievalTelemetryEvent(s).zeroHit == true)
    }

    @Test
    func `non-empty hits are not zero-hit and carry space`() {
        let space = UUID()
        let s = RetrievalTelemetrySample.from(
            tenantID: UUID(),
            distances: [0.2],
            source: .agenticSearch,
            spaceID: space,
            limit: 8
        )
        let event = RetrievalTelemetryEvent(s)
        #expect(event.zeroHit == false)
        #expect(event.spaceID == space)
        #expect(event.sourcePath == "agentic_search")
        #expect(event.limitRequested == 8)
    }
}
