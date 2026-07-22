@testable import App
import Foundation
import Testing

/// Pure SelfImprovement policy helpers — no Postgres.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct SelfImprovementPolicyTests {
    @Test
    func `conservative change accepts small patch`() {
        let old = (1 ... 30).map { "line-\($0)" }.joined(separator: "\n")
        let new = old + "\nline-extra"
        #expect(SelfImprovementService.isConservativeChange(from: old, to: new))
    }

    @Test
    func `conservative change rejects broad rewrite`() {
        let old = (1 ... 40).map { "keep-\($0)" }.joined(separator: "\n")
        let new = (1 ... 40).map { "rewrite-\($0)" }.joined(separator: "\n")
        #expect(!SelfImprovementService.isConservativeChange(from: old, to: new))
    }

    @Test
    func `sha256 is stable for approve base comparison`() {
        let soul = "# SOUL.md\n\nHello\n"
        #expect(SelfImprovementService.sha256(soul) == SelfImprovementService.sha256(soul))
        #expect(SelfImprovementService.sha256(soul) != SelfImprovementService.sha256(soul + "x"))
    }

    @Test
    func `valid resource name rejects path traversal and empties`() {
        #expect(SelfImprovementService.validResourceName("my-skill_1"))
        #expect(!SelfImprovementService.validResourceName(""))
        #expect(!SelfImprovementService.validResourceName("../etc"))
        #expect(!SelfImprovementService.validResourceName(String(repeating: "a", count: 81)))
    }

    @Test
    func `decodeJSON strips markdown fences`() throws {
        struct Envelope: Decodable {
            let needed: Bool
            let summary: String
        }
        let raw = """
        ```json
        {"needed":false,"summary":"no drift"}
        ```
        """
        let decoded = try SelfImprovementService.decodeJSON(Envelope.self, from: raw)
        #expect(decoded.needed == false)
        #expect(decoded.summary == "no drift")
    }

    @Test
    func `safe defaults match Lumina product contract`() {
        let defaults = ImprovementSettingsDTO.safeDefault
        #expect(defaults.enabled)
        #expect(defaults.curatorEnabled)
        #expect(defaults.intervalHours == 168)
        #expect(defaults.consolidate == true)
        #expect(defaults.pruneBuiltins == false)
        #expect(defaults.soulReviewEnabled)
        #expect(defaults.soulReviewWindowDays == 14)
        #expect(defaults.modelMode == .economy)
    }
}
