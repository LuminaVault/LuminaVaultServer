@testable import App
import Foundation
import Testing

/// Hermes Mirror task 5 — the kb-* skills ship as a SwiftPM resource so the
/// mirror can install them onto a user's Hermes; the Hermes image bakes the
/// same tree.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesBundledSkillsTests {
    @Test
    func `bundle ships every kb skill with frontmatter`() async throws {
        let skills = try await HermesBundledSkills().kbSkills()
        #expect(skills.map(\.name) == ["kb-compile", "kb-import", "kb-ingest", "kb-merge-vault", "kb-output"])
        for skill in skills {
            #expect(skill.content.hasPrefix("---\nname: \(skill.name)\n"), "\(skill.name) frontmatter")
            #expect(!FilesystemHermesTransport.frontmatterDescription(skill.content).isEmpty, "\(skill.name) description")
        }
        #expect(skills.contains { $0.name == HermesBundledSkills.compileSkillName })
    }

    @Test
    func `missing root yields no skills`() async throws {
        let none = HermesBundledSkills(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(try await none.kbSkills().isEmpty)
        #expect(try await HermesBundledSkills(root: nil).kbSkills().isEmpty)
    }
}
