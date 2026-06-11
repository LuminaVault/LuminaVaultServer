@testable import App
import LuminaVaultShared
import Testing

/// Pure-function tests for Lumina Jobs P3 — the classifier parse, slug, and
/// SKILL.md authoring (no DB / LLM needed). The authoring test parses the
/// generated manifest back through the real parser to prove a created job is
/// a valid, schedulable vault skill.
struct JobsTests {
    @Test
    func `classifier parses a recurring job`() {
        let p = JobIntentClassifier.parse(#"""
        {"isJob":true,"title":"AAPL watch","cron":"0 8 * * *","scheduleHuman":"Every day at 8 AM","domain":"stocks","spec":"Report AAPL + TSLA price"}
        """#)
        #expect(p.isJob)
        #expect(p.cron == "0 8 * * *")
        #expect(p.domain == "stocks")
        #expect(p.title == "AAPL watch")
    }

    @Test
    func `classifier tolerates a json fence, rejects non-jobs and garbage`() {
        #expect(JobIntentClassifier.parse("```json\n{\"isJob\":true,\"cron\":\"0 9 * * 1\"}\n```").isJob)
        #expect(JobIntentClassifier.parse(#"{"isJob":false}"#).isJob == false)
        #expect(JobIntentClassifier.parse("not json at all").isJob == false)
    }

    @Test
    func `slug is namespaced and filesystem-safe`() {
        #expect(JobAuthoring.slug("Daily Stock Prices!") == "job-daily-stock-prices")
        #expect(JobAuthoring.slug("AI / Papers").hasPrefix("job-"))
    }

    @Test
    func `authored SKILL.md parses as a valid scheduled vault skill`() throws {
        let md = JobAuthoring.skillMarkdown(
            slug: "job-x", title: "Stock Watch", cron: "0 8 * * *", domain: "stocks", spec: "Report prices"
        )
        let manifest = try SkillManifestParser().parse(source: .vault, contents: md)
        #expect(manifest.name == "job-x")
        #expect(manifest.schedule == "0 8 * * *")
    }

    @Test
    func `one-shot SKILL.md omits the schedule (run_at lives on skills_state)`() throws {
        let md = JobAuthoring.skillMarkdown(
            slug: "job-y", title: "One Off", cron: nil, domain: nil, spec: "Do it once"
        )
        #expect(!md.contains("schedule:"))
        let manifest = try SkillManifestParser().parse(source: .vault, contents: md)
        #expect(manifest.name == "job-y")
        #expect(manifest.schedule == nil)
    }
}
