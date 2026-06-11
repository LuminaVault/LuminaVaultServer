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

    func testAutonomyRendersOperations() {
        XCTAssertTrue(render(.warm, .secondBrain, .act).lowercased().contains("act"))
        XCTAssertTrue(render(.warm, .secondBrain, .askFirst).lowercased().contains("confirm"))
    }

    func testNoPlaceholderCommentsRemain() {
        XCTAssertFalse(render().contains("<!--"), "composed SOUL must be filled, not templated")
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
}
