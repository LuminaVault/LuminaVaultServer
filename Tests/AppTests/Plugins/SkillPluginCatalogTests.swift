@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// HER-43 Slice 3a — skills-as-plugins bridge. Pure-logic (no DB / no HTTP),
/// avoiding the AsyncKit teardown SIGILL (HER-310).
@Suite("Skill plugin catalog bridge")
struct SkillPluginCatalogTests {
    @Test
    func `lv skill slug round-trips and rejects non-skill slugs`() {
        let entry = SkillPluginCatalog.entry(forSkillName: "pattern-detector", description: "Finds patterns.")
        #expect(entry.slug == "skill-pattern-detector")
        #expect(entry.category == .skill)
        #expect(entry.capabilityKind == .skill)
        #expect(entry.configFields.isEmpty)
        #expect(entry.name == "Pattern Detector")

        #expect(SkillPluginCatalog.lvSkillName(fromSlug: "skill-pattern-detector") == "pattern-detector")
        #expect(SkillPluginCatalog.lvSkillName(fromSlug: "readwise") == nil)
        #expect(SkillPluginCatalog.lvSkillName(fromSlug: "hermes-foo") == nil)
        #expect(SkillPluginCatalog.lvSkillName(fromSlug: "skill-") == nil)
    }

    @Test
    func `titleize and summarize format display fields`() {
        #expect(SkillPluginCatalog.titleize("belief_evolution") == "Belief Evolution")
        #expect(SkillPluginCatalog.titleize("kb-compile") == "Kb Compile")
        let long = String(repeating: "x", count: 200)
        #expect(SkillPluginCatalog.summarize("first line\nsecond") == "first line")
        #expect(SkillPluginCatalog.summarize(long).count == 140) // 139 + "…"
    }

    @Test
    func `parseHermesSkills accepts object, array, and string forms; dedupes`() {
        let object = Data(#"{"skills":[{"name":"gif-search","description":"Find GIFs"},{"name":"gif-search"}]}"#.utf8)
        let objEntries = SkillPluginCatalog.parseHermesSkills(object)
        #expect(objEntries.count == 1)
        #expect(objEntries[0].slug == "hermes-gif-search")
        #expect(objEntries[0].publisher == "Hermes")
        #expect(objEntries[0].description == "Find GIFs")

        let bareArray = Data(#"["alpha","beta"]"#.utf8)
        #expect(SkillPluginCatalog.parseHermesSkills(bareArray).map(\.slug) == ["hermes-alpha", "hermes-beta"])

        let dataKey = Data(#"{"data":[{"id":"zeta"}]}"#.utf8)
        #expect(SkillPluginCatalog.parseHermesSkills(dataKey).map(\.slug) == ["hermes-zeta"])

        #expect(SkillPluginCatalog.parseHermesSkills(Data("not json".utf8)).isEmpty)
        #expect(SkillPluginCatalog.parseHermesSkills(Data(#"{"other":1}"#.utf8)).isEmpty)
    }
}
