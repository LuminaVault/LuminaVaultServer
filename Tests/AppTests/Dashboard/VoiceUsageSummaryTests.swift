@testable import App
import Foundation
import Testing

/// Unit conversion for the voice block on `GET /v1/analytics/usage-summary`.
///
/// Pure arithmetic, but the kind that is wrong quietly: a factor-of-ten slip
/// in a cost column looks plausible on a dashboard for months.
struct VoiceUsageSummaryTests {
    // MARK: - Minutes

    @Test
    func `milliseconds become minutes to one decimal`() {
        #expect(AnalyticsController.minutes(fromMilliseconds: 60000) == 1.0)
        #expect(AnalyticsController.minutes(fromMilliseconds: 90000) == 1.5)
        #expect(AnalyticsController.minutes(fromMilliseconds: 0) == 0)
    }

    /// A single short voice note must not read as zero minutes: "we recorded
    /// 40 calls and 0.0 minutes" reads as a broken meter.
    @Test
    func `a short clip rounds to a visible fraction`() {
        // 9 seconds = 0.15 min → 0.2 at one decimal.
        #expect(AnalyticsController.minutes(fromMilliseconds: 9000) == 0.2)
    }

    // MARK: - Cents

    @Test
    func `micro-usd becomes whole cents`() {
        // 1 cent = 10_000 micro-USD.
        #expect(AnalyticsController.cents(fromUsdMicros: 10000) == 1)
        #expect(AnalyticsController.cents(fromUsdMicros: 1_000_000) == 100)
    }

    /// Sub-cent spend truncates to zero, matching `estimatedCostCents` on the
    /// same response. Both costs on one payload must share a unit and a
    /// rounding rule, or they cannot be compared.
    @Test
    func `sub-cent spend truncates like the llm cost column does`() {
        #expect(AnalyticsController.cents(fromUsdMicros: 6000) == 0)
        #expect(AnalyticsController.cents(fromUsdMicros: 9999) == 0)
    }
}
