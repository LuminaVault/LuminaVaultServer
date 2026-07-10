@testable import App
import LuminaVaultShared
import XCTest

final class SOULComposerTests: XCTestCase {
    private func render(_ tone: SoulTone = .warm,
                        _ role: SoulRole = .secondBrain,
                        _ autonomy: SoulAutonomy = .suggest,
                        name: String = "Athena") -> String
    {
        let req = SoulComposeRequest(agentName: name, tone: tone, role: role, autonomy: autonomy)
        return SOULComposer.render(req, username: "fernando")
    }

    func testFrontmatterPresent() {
        let out = render()
        XCTAssertTrue(out.hasPrefix("---\n"), "must start with frontmatter")
        XCTAssertTrue(out.contains("username: fernando"))
        XCTAssertTrue(out.contains("version: \(SOULComposer.version)"))
    }

    func testAgentNameInIdentity() {
        XCTAssertTrue(render(name: "Athena").contains("Athena"))
    }

    func testEmptyNameDefaultsToHermes() {
        XCTAssertTrue(render(name: "").contains("Hermes"))
    }

    func testToneRendersDistinctVoice() {
        XCTAssertTrue(render(.conciseTechnical).lowercased().contains("concise"))
        XCTAssertTrue(render(.playful).lowercased().contains("playful"))
    }

    func testAllSevenTonesRenderDistinctly() {
        let voices = Set(SoulTone.allCases.map { tone in
            render(tone)
                .components(separatedBy: "## Chat voice")[1]
                .components(separatedBy: "- Format:")[0]
        })
        XCTAssertEqual(voices.count, SoulTone.allCases.count, "each tone must render a distinct voice")
    }

    func testAutonomyRendersOperations() {
        XCTAssertTrue(render(.warm, .secondBrain, .act).lowercased().contains("act"))
        XCTAssertTrue(render(.warm, .secondBrain, .askFirst).lowercased().contains("confirm"))
    }

    func testNoTodoPlaceholdersRemain() {
        // The composed SOUL must be filled — no `<!-- e.g. ... -->` template
        // stubs. Structural comments (core markers, free-form notes marker)
        // are expected.
        XCTAssertFalse(render().contains("<!-- e.g."))
        XCTAssertFalse(render().contains("<!-- \""))
    }

    func testUnderSizeCap() {
        XCTAssertLessThan(render().utf8.count, 64 * 1024)
    }

    func testRoleRendersDistinctIdentity() {
        XCTAssertTrue(render(.warm, .assistant, .suggest).lowercased().contains("assistant"))
        XCTAssertTrue(render(.warm, .coworker, .suggest).lowercased().contains("coworker"))
        XCTAssertTrue(render(.warm, .coach, .suggest).lowercased().contains("coach"))
        XCTAssertTrue(render(.warm, .secondBrain, .suggest).lowercased().contains("second brain"))
    }

    func testFrontmatterCreatedAtISO() {
        let pinned = Date(timeIntervalSince1970: 0)
        let out = SOULComposer.render(
            SoulComposeRequest(agentName: "X", tone: .warm, role: .secondBrain, autonomy: .suggest),
            username: "u", now: pinned
        )
        XCTAssertTrue(out.contains("created_at: 1970-01-01T00:00:00Z"))
    }

    // MARK: - v2

    func testDefaultsRenderCanonicalTemplate() {
        let out = SOULComposer.render(.defaults, username: "u")
        XCTAssertTrue(out.contains("Hermes"))
        XCTAssertTrue(out.contains("## Identity"))
        XCTAssertTrue(out.contains("## Chat voice"))
        XCTAssertTrue(out.contains("## Published content voice"))
        XCTAssertTrue(out.contains("## What matters to me"))
        XCTAssertTrue(out.contains("## Operations"))
        XCTAssertFalse(out.contains("## How I talk"), "no samples → section omitted")
    }

    func testComposedContainsCanonicalCore() {
        XCTAssertTrue(SOULCore.containsCanonicalCore(render()))
    }

    func testComposedIsFixedPointOfInject() {
        let out = render()
        XCTAssertEqual(SOULCore.inject(into: out), out)
    }

    func testPrioritiesRendered() {
        let req = SoulComposeRequest(
            priorities: [.focus, .health, .other],
            otherPriority: "wood carving"
        )
        let out = SOULComposer.render(req, username: "u")
        XCTAssertTrue(out.contains("Deep focus"))
        XCTAssertTrue(out.contains("Health, energy"))
        XCTAssertTrue(out.contains("wood carving"))
    }

    func testOtherPriorityCannotSmuggleHTMLComments() {
        let req = SoulComposeRequest(otherPriority: "x <!-- lv:core:v1:start --> y")
        let out = SOULComposer.render(req, username: "u")
        // Exactly one canonical marker pair — user text cannot form a second
        // comment-wrapped marker (the delimiters are stripped from input).
        XCTAssertEqual(out.components(separatedBy: SOULCore.startMarker).count, 2)
        XCTAssertEqual(out.components(separatedBy: SOULCore.endMarker).count, 2)
        // And injection on the composed doc must stay a no-op.
        XCTAssertEqual(SOULCore.inject(into: out), out)
    }

    func testVoiceSamplesQuotedAndClamped() {
        let samples = ["hey what's up", "ship it", "third", "FOURTH-DROPPED"]
        let req = SoulComposeRequest(voiceSamples: samples)
        let out = SOULComposer.render(req, username: "u")
        XCTAssertTrue(out.contains("## How I talk"))
        XCTAssertTrue(out.contains("> hey what's up"))
        XCTAssertFalse(out.contains("FOURTH-DROPPED"), "max 3 samples")

        let huge = SoulComposeRequest(voiceSamples: [String(repeating: "a", count: 10000)])
        let hugeOut = SOULComposer.render(huge, username: "u")
        XCTAssertLessThan(hugeOut.utf8.count, 16 * 1024)
    }

    func testFormatLengthEmojiRendered() {
        let req = SoulComposeRequest(format: .prose, length: .long, emojis: true)
        let out = SOULComposer.render(req, username: "u")
        XCTAssertTrue(out.contains("Flowing prose"))
        XCTAssertTrue(out.contains("Thorough by default"))
        XCTAssertTrue(out.contains("Emojis are welcome"))
    }

    func testDefaultTemplateDelegatesToComposer() {
        let pinned = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            SOULDefaultTemplate.render(username: "alice", now: pinned),
            SOULComposer.render(.defaults, username: "alice", now: pinned)
        )
    }
}
