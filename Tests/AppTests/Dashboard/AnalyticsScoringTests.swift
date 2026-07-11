import Testing
@testable import App

@Suite("Analytics memory health scoring")
struct AnalyticsScoringTests {
    @Test("weights components transparently")
    func weightedScore() {
        #expect(AnalyticsController.weightedHealthScore(
            freshness: 80,
            engagement: 60,
            organization: 50,
            review: 100
        ) == 73)
    }

    @Test("clamps malformed component inputs")
    func clampedScore() {
        #expect(AnalyticsController.weightedHealthScore(
            freshness: 200,
            engagement: 200,
            organization: 200,
            review: 200
        ) == 100)
        #expect(AnalyticsController.weightedHealthScore(
            freshness: -100,
            engagement: -100,
            organization: -100,
            review: -100
        ) == 0)
    }
}
