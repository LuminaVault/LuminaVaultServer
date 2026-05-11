@testable import App
import Foundation
import Testing

/// HER-147 — pure-math unit tests for the scoring formula.
/// No DB / Hermes needed.
struct MemoryScoringTests {
    @Test
    func `fresh untouched memory scores one`() {
        // accessCount=0, queryHitCount=0, age=0 → exp(0)=1.0.
        // With default weights: 2*ln(1) + 3*ln(1) + 1*1 = 1.0.
        let now = Date()
        let score = MemoryScoring.compute(
            accessCount: 0,
            queryHitCount: 0,
            createdAt: now,
            now: now,
        )
        #expect(abs(score - 1.0) < 1e-9)
    }

    @Test
    func `recency decays at halflife`() {
        let now = Date()
        let halflifeAgo = now.addingTimeInterval(-30 * 86400)
        let score = MemoryScoring.compute(
            accessCount: 0,
            queryHitCount: 0,
            createdAt: halflifeAgo,
            now: now,
            config: .default,
        )
        // exp(-30/30) = e^-1 ≈ 0.3678794
        let expected = exp(-1.0)
        #expect(abs(score - expected) < 1e-6)
    }

    @Test
    func `access and query hits dominate old row`() {
        let now = Date()
        let veryOld = now.addingTimeInterval(-365 * 86400)
        // 50 accesses, 20 queries on a year-old row:
        // 2*ln(51) + 3*ln(21) + 1*exp(-365/30)
        // ≈ 2*3.93 + 3*3.04 + ≈0
        // ≈ 7.86 + 9.13 ≈ 16.99
        let score = MemoryScoring.compute(
            accessCount: 50,
            queryHitCount: 20,
            createdAt: veryOld,
            now: now,
        )
        #expect(score > 15)
    }

    @Test
    func `nil created at treated as now`() {
        // ageDays should clamp to 0 — recency term is full strength.
        let score = MemoryScoring.compute(
            accessCount: 0,
            queryHitCount: 0,
            createdAt: nil,
            now: Date(),
        )
        #expect(abs(score - 1.0) < 1e-9)
    }

    @Test
    func `zero age never negative`() {
        // Future `createdAt` (clock skew) must not produce age<0 → exp(>0) blowup.
        let now = Date()
        let future = now.addingTimeInterval(86400) // 1 day in the future
        let score = MemoryScoring.compute(
            accessCount: 0,
            queryHitCount: 0,
            createdAt: future,
            now: now,
        )
        #expect(score <= 1.0 + 1e-9, "skewed timestamps must not amplify the recency term")
    }
}
