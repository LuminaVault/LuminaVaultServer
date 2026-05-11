import Foundation
import Testing

@testable import App

/// HER-148 scaffold smoke tests. Documents the parser contract: every
/// built-in SKILL.md must be loadable from `Bundle.module` and feed
/// `SkillManifestParser`. Currently the parser is a stub that throws
/// `SkillManifestError.malformedFrontmatter` — that's the asserted
/// behavior so the test stays green until HER-167 implements parsing,
/// at which point the assertions flip.
@Suite
struct SkillManifestTests {

    /// Built-in skill names shipped via `Resources/Skills/<name>/SKILL.md`.
    /// Adding a new built-in to HER-173 means adding it here too.
    private static let builtinSkillNames = [
        "daily-brief",
        "kb-compile",
        "weekly-memo",
        "health-correlate",
        "capture-enrich"
    ]

    @Test
    func builtinResourcesArePresentAndNonEmpty() throws {
        for name in Self.builtinSkillNames {
            let url = Bundle.module.url(
                forResource: "SKILL",
                withExtension: "md",
                subdirectory: "Skills/\(name)"
            )
            try #require(url != nil, "missing built-in SKILL.md for \(name)")
            let contents = try String(contentsOf: url!, encoding: .utf8)
            #expect(contents.hasPrefix("---\n"), "frontmatter must lead \(name)/SKILL.md")
            #expect(contents.contains("name: \(name)"), "frontmatter name must match dir for \(name)")
        }
    }

    @Test
    func parserStubRejectsAllManifestsUntilHER167() throws {
        let parser = SkillManifestParser()
        for name in Self.builtinSkillNames {
            let url = Bundle.module.url(
                forResource: "SKILL",
                withExtension: "md",
                subdirectory: "Skills/\(name)"
            )
            try #require(url != nil)
            let contents = try String(contentsOf: url!, encoding: .utf8)
            #expect(throws: SkillManifestError.self) {
                _ = try parser.parse(source: .builtin, contents: contents)
            }
        }
    }
}
