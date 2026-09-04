@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Hermes Mirror Phase 2 (Collect) — the pure parts of the `hermes_job_runs`
/// row: the 256 KiB output cap and the tokens JSONB round-trip.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesJobRunModelTests {
    @Test
    func `short output is stored verbatim`() {
        #expect(HermesJobRun.truncate("# Digest\n") == "# Digest\n")
        #expect(HermesJobRun.truncate("").isEmpty)
    }

    @Test
    func `oversized output is cut at the cap on a UTF-8 boundary and marked`() {
        // Multi-byte scalars so a naive byte cut would split one.
        let long = String(repeating: "é", count: HermesJobRun.maxOutputBytes)
        let truncated = HermesJobRun.truncate(long)
        #expect(truncated != long)
        #expect(truncated.hasSuffix(HermesJobRun.truncationMarker))
        // Valid UTF-8: the cut fell on a grapheme boundary, not mid-scalar.
        #expect(!truncated.contains("\u{FFFD}"))
        let body = truncated.replacingOccurrences(of: HermesJobRun.truncationMarker, with: "")
        #expect(body.utf8.count <= HermesJobRun.maxOutputBytes)
        #expect(body.allSatisfy { $0 == "é" })
    }

    @Test
    func `tokens are absent when Hermes reported none and typed when it did`() {
        #expect(HermesJobRun.tokens(input: nil, output: nil) == nil)
        #expect(HermesJobRun.tokens(input: 120, output: 340) == HermesJobRunTokensDTO(input: 120, output: 340))
        #expect(HermesJobRun.tokens(input: nil, output: 7) == HermesJobRunTokensDTO(input: nil, output: 7))
    }

    @Test
    func `the row maps to the wire DTO with an unknown status falling back to ok`() {
        let started = Date(timeIntervalSince1970: 1_756_800_000)
        let row = HermesJobRun(
            tenantID: UUID(), jobID: "digest",
            run: HermesMirrorJobRun(key: "cron_digest_1", status: .error, startedAt: started, finishedAt: started, error: "boom", tokensIn: 1, tokensOut: 2),
            collectedAt: started
        )
        row.id = UUID()
        var dto = row.dto()
        #expect(dto.runKey == "cron_digest_1")
        #expect(dto.status == .error)
        #expect(dto.error == "boom")
        #expect(dto.tokens == HermesJobRunTokensDTO(input: 1, output: 2))
        #expect(dto.collectedAt == started)

        row.status = "not-a-status"
        dto = row.dto()
        #expect(dto.status == .ok)
    }
}
