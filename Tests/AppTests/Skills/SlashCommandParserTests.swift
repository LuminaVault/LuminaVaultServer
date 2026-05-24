@testable import App
import Testing

struct SlashCommandParserTests {
    @Test
    func `kb ingest aliases route to kb compile`() {
        #expect(SlashCommandParser.parse("/kb-compile")?.kind == .kbCompile)
        #expect(SlashCommandParser.parse("/kb-ingest")?.kind == .kbCompile)
    }

    @Test
    func `known synthesis aliases preserve topic input`() {
        let patterns = SlashCommandParser.parse("/patterns sleep quality")
        #expect(patterns?.kind == .skill(name: "pattern-detector"))
        #expect(patterns?.input == "sleep quality")
        #expect(patterns?.arguments == ["topic": "sleep quality"])

        let contradictions = SlashCommandParser.parse("/contradict diet notes")
        #expect(contradictions?.kind == .skill(name: "contradiction-detector"))
        #expect(contradictions?.arguments == ["topic": "diet notes"])
    }

    @Test
    func `beliefs requires a topic`() {
        let help = SlashCommandParser.parse("/beliefs")
        #expect(help?.kind == .help(markdown: "Usage: `/beliefs <topic>`"))

        let parsed = SlashCommandParser.parse("/beliefs work")
        #expect(parsed?.kind == .skill(name: "belief-evolution"))
        #expect(parsed?.arguments == ["topic": "work"])
    }

    @Test
    func `generic slash maps to skill name`() {
        let parsed = SlashCommandParser.parse("/weekly-memo last week")
        #expect(parsed?.kind == .skill(name: "weekly-memo"))
        #expect(parsed?.input == "last week")
        #expect(parsed?.arguments == ["input": "last week"])
    }

    @Test
    func `non slash is ignored`() {
        #expect(SlashCommandParser.parse("hello") == nil)
    }
}
