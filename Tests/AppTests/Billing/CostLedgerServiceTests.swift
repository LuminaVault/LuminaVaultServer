@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Pure-function tests for the cost-ledger money math + retry hint. No DB,
/// no actor I/O — `ProviderCostRate.usdMicros` and `secondsUntilUTCMidnight`
/// are deterministic.
struct CostLedgerServiceTests {
    // MARK: - ProviderCostRate.usdMicros

    @Test
    func `cost is per-million-token rate applied to in and out`() {
        // $0.50 / Mtok in, $1.50 / Mtok out (in micro-USD per Mtok).
        let rate = ProviderCostRate(
            inputPerMtokUsdMicros: 500_000,
            outputPerMtokUsdMicros: 1_500_000,
        )
        // 1M in + 1M out = 0.50 + 1.50 = $2.00 = 2_000_000 micros.
        #expect(rate.usdMicros(tokensIn: 1_000_000, tokensOut: 1_000_000) == 2_000_000)
        // Half a million in only = $0.25 = 250_000 micros.
        #expect(rate.usdMicros(tokensIn: 500_000, tokensOut: 0) == 250_000)
    }

    @Test
    func `zero and negative tokens clamp to zero cost`() {
        let rate = ProviderCostRate(inputPerMtokUsdMicros: 500_000, outputPerMtokUsdMicros: 500_000)
        #expect(rate.usdMicros(tokensIn: 0, tokensOut: 0) == 0)
        #expect(rate.usdMicros(tokensIn: -100, tokensOut: -100) == 0)
    }

    @Test
    func `small token counts round down (integer micro-USD)`() {
        // 1 token at $0.50/Mtok = 0.5 micro-USD → integer division floors to 0.
        let rate = ProviderCostRate(inputPerMtokUsdMicros: 500_000, outputPerMtokUsdMicros: 0)
        #expect(rate.usdMicros(tokensIn: 1, tokensOut: 0) == 0)
        // 3 tokens at $1.00/Mtok = 3 micro-USD.
        let rate2 = ProviderCostRate(inputPerMtokUsdMicros: 1_000_000, outputPerMtokUsdMicros: 0)
        #expect(rate2.usdMicros(tokensIn: 3, tokensOut: 0) == 3)
    }

    // MARK: - Retry hint

    @Test
    func `retry hint is positive and within a day`() {
        let secs = CostLedgerService.secondsUntilUTCMidnight()
        #expect(secs >= 60)
        #expect(secs <= 86400)
    }

    @Test
    func `retry hint from a known instant points at next UTC midnight`() throws {
        // 2026-06-03 23:00:00 UTC → 1 hour to midnight.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 3
        comps.hour = 23; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(cal.date(from: comps))
        let secs = CostLedgerService.secondsUntilUTCMidnight(now: now)
        #expect(secs == 3600)
    }
}
