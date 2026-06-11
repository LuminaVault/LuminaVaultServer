@testable import App
import Foundation
import Testing

/// Pure JSON round-trip for the card `extra` payload (no DB). Proves the
/// promotion config survives the JSONB column encode/decode.
struct CardExtraTests {
    @Test
    func `job config round-trips through JSON`() throws {
        let spaceID = UUID()
        let original = CardExtra(job: CardJobConfig(
            source: "vault",
            cron: "0 9 * * 1",
            domain: "stocks",
            prompt: "Report AAPL",
            spaceID: spaceID,
            jobSlug: "job-report-aapl",
            promotedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CardExtra.self, from: data)
        #expect(decoded == original)
        #expect(decoded.job?.cron == "0 9 * * 1")
        #expect(decoded.job?.spaceID == spaceID)
        #expect(decoded.job?.jobSlug == "job-report-aapl")
    }

    @Test
    func `empty extra round-trips with nil job`() throws {
        let data = try JSONEncoder().encode(CardExtra())
        let decoded = try JSONDecoder().decode(CardExtra.self, from: data)
        #expect(decoded.job == nil)
    }

    @Test
    func `source defaults to vault`() {
        #expect(CardJobConfig().source == "vault")
    }
}
