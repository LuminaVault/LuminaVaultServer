@testable import App
import Foundation
import Testing

/// HER-43 Slice 3b — hub skill install/uninstall. Pure validation logic (no
/// docker / no DB), avoiding the AsyncKit teardown SIGILL (HER-310).
@Suite("Hermes hub skill ref validation", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesHubSkillsServiceTests {
    @Test
    func `accepts hub ids and urls, trimming whitespace`() throws {
        #expect(try HermesHubSkillsService.validatedRef("gif-search") == "gif-search")
        #expect(try HermesHubSkillsService.validatedRef("  amanning3390/hermeshub:gif-search  ") == "amanning3390/hermeshub:gif-search")
        #expect(try HermesHubSkillsService.validatedRef("https://example.com/SKILL.md") == "https://example.com/SKILL.md")
    }

    @Test
    func `rejects empty, whitespace-internal, control chars, leading dash, and overlong`() {
        for bad in ["", "   ", "two words", "has\ttab", "line\nbreak", "--help", "-rf", String(repeating: "x", count: 513)] {
            #expect(throws: (any Error).self) {
                _ = try HermesHubSkillsService.validatedRef(bad)
            }
        }
    }
}
