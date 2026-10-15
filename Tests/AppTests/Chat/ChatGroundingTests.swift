@testable import App
import Foundation
import Testing

/// Chat grounding may now find nothing relevant. Close hits and exact keyword
/// hits stay; far, keyword-less hits go.
struct ChatGroundingTests {
    private func hit(distance: Float, lexical: Float? = nil) -> MemorySearchResult {
        MemorySearchResult(
            id: UUID(),
            tenantID: UUID(),
            content: "x",
            createdAt: nil,
            distance: distance,
            lexicalScore: lexical
        )
    }

    @Test
    func `close hits are kept and far ones dropped`() {
        let kept = ChatGrounding.relevant([hit(distance: 0.2), hit(distance: 0.9)], maxDistance: 0.6)
        #expect(kept.map(\.distance) == [0.2])
    }

    @Test
    func `an exact keyword match is kept however far its embedding is`() {
        let kept = ChatGrounding.relevant([hit(distance: 1.0, lexical: 0.1)], maxDistance: 0.6)
        #expect(kept.count == 1)
    }

    @Test
    func `nothing relevant is an empty answer, not the nearest five`() {
        #expect(ChatGrounding.relevant([hit(distance: 0.8), hit(distance: 0.95)], maxDistance: 0.6).isEmpty)
    }
}
