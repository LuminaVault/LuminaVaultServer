@testable import App
import Foundation
import Testing

/// HER-191 scaffold. Three layers:
///
/// 1. **Manifest sanity** — `SKILL.md` is shipped in `Bundle.module` and
///    its frontmatter declares the contracted name, capability, and
///    output path.
/// 2. **Prompt contract** — the body of `SKILL.md` mentions the
///    structural elements the iOS client and the runner depend on:
///    topic-required validation, `[[memory:<uuid>]]` citations,
///    chronological `### YYYY-MM-DD — <label>` anchors, `### Pattern`
///    closing block, `timelineEntries` structured response, and the
///    `reflections/<date>/beliefs-<slug>.md` persistence path.
/// 3. **Fixture vault** — declares the seeded memories the HER-169
///    runner will consume when this test flips from scaffold-mode to
///    a live E2E test. Five memories on "remote work" spanning three
///    months with an intentional opinion shift in the middle. The
///    fixture is exposed via `Self.fixtureMemories` so HER-169 can
///    pull it in without re-deriving the shape.
///
/// The live SkillRunner assertion is deliberately omitted — HER-169
/// throws `HTTPError(.notImplemented)`, and the route-level scaffold
/// is already covered by `SkillsControllerTests`. Once HER-169 lands,
/// add a fourth test here that seeds `Self.fixtureMemories`, runs the
/// skill with `topic: "remote work"`, and asserts ≥3 chronological
/// timeline anchors with shift acknowledgement.
struct BeliefEvolutionTests {
    private static let skillName = "belief-evolution"

    /// Seeded memories for the HER-169 live-run path. Three months of
    /// opinions on remote work with a deliberate inflection mid-window.
    /// Dates are ISO 8601 to keep cron/timezone parsing out of the
    /// fixture surface.
    struct FixtureMemory: Hashable {
        let id: UUID
        let createdAt: String
        let body: String
    }

    static let fixtureMemories: [FixtureMemory] = [
        FixtureMemory(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            createdAt: "2026-01-12T09:00:00Z",
            body: "Remote work is non-negotiable for me. The flexibility is the single biggest reason I took this role over the on-site offer.",
        ),
        FixtureMemory(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            createdAt: "2026-01-30T18:20:00Z",
            body: "Two weeks in and remote is paying off — I finished the entire migration without a single context-switch interruption.",
        ),
        FixtureMemory(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            createdAt: "2026-02-28T11:45:00Z",
            body: "After the offsite I realised how much faster decisions happen in person. Maybe full-remote isn't strictly better, it's a tradeoff.",
        ),
        FixtureMemory(
            id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            createdAt: "2026-03-22T14:10:00Z",
            body: "Pairing in person twice a week genuinely fixed the design-review bottleneck. I'd take hybrid over full remote now if I'm honest.",
        ),
        FixtureMemory(
            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            createdAt: "2026-04-15T08:30:00Z",
            body: "Settling on the truth: I want hybrid, leaning 3/2. Full remote was a phase, not a value.",
        ),
    ]

    @Test
    func `builtin SKILL md is bundled and declares belief-evolution`() throws {
        let url = Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "Skills/\(Self.skillName)",
        )
        try #require(url != nil, "missing SKILL.md for \(Self.skillName)")
        let contents = try String(contentsOf: #require(url), encoding: .utf8)
        #expect(contents.hasPrefix("---\n"), "frontmatter must lead")
        #expect(contents.contains("name: \(Self.skillName)"))
        #expect(contents.contains("capability: high"))
        #expect(contents.contains("reflections/{date}/beliefs-{slug}.md"))
    }

    @Test
    func `prompt body documents required structural contract`() throws {
        let url = try #require(Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "Skills/\(Self.skillName)",
        ))
        let body = try String(contentsOf: url, encoding: .utf8)

        // Topic-required validation surfaces in the prompt (else parser
        // can't wire a 400 response in HER-169).
        #expect(body.contains("requires a `topic`"))

        // Citation format the iOS renderer parses.
        #expect(body.contains("[[memory:<uuid>]]"))

        // Timeline anchor heading shape (`### YYYY-MM-DD — <label>`).
        #expect(body.contains("### <YYYY-MM-DD>"))

        // Closing summary block.
        #expect(body.contains("### Pattern"))

        // Structured response payload key consumed by iOS.
        #expect(body.contains("timelineEntries"))

        // Persistence path for `save=true`.
        #expect(body.contains("reflections/<YYYY-MM-DD>/beliefs-<slug>.md"))

        // Minimum anchor count promised to acceptance criteria.
        #expect(body.contains("Minimum 3 anchors"))
    }

    @Test
    func `fixture memories are chronologically ordered and span 3 months`() throws {
        let dates = Self.fixtureMemories.map(\.createdAt)
        #expect(dates == dates.sorted(), "fixture must be chronologically ordered")
        #expect(Self.fixtureMemories.count == 5, "spec requires exactly 5 seed memories")

        // First and last must straddle ≥ 3 calendar months to give the
        // runner enough temporal spread to detect a shift.
        let firstYearMonth = try String(#require(Self.fixtureMemories.first?.createdAt.prefix(7)))
        let lastYearMonth = try String(#require(Self.fixtureMemories.last?.createdAt.prefix(7)))
        #expect(firstYearMonth == "2026-01")
        #expect(lastYearMonth == "2026-04")

        // All fixture memory ids must be unique — the runner cites them
        // by UUID and duplicates would corrupt timeline rendering.
        let ids = Self.fixtureMemories.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
