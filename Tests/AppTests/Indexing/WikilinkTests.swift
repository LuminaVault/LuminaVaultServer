@testable import App
import Foundation
import Testing

/// Parsing `[[wikilinks]]` out of real markdown.
struct WikilinkParsingTests {
    @Test
    func `a bare link yields its target`() {
        let links = Wikilinks.extract(from: "See [[hermes]] for details.")
        #expect(links.count == 1)
        #expect(links[0].targetSlug == "hermes")
        #expect(links[0].line == 1)
        #expect(links[0].label == nil)
        #expect(links[0].targetHeading == nil)
    }

    @Test
    func `alias, heading, and path are split apart`() {
        let links = Wikilinks.extract(from: "[[projects/hermes#Fallbacks|how routing fails]]")
        let link = try! #require(links.first)
        #expect(link.targetSlug == "projects/hermes")
        #expect(link.targetHeading == "Fallbacks")
        #expect(link.label == "how routing fails")
        #expect(link.rawTarget == "projects/hermes#Fallbacks|how routing fails")
    }

    @Test
    func `several links on one line are all found with the right line number`() {
        let source = "intro\n[[a]] and [[b]] and [[c]]\noutro"
        let links = Wikilinks.extract(from: source)
        #expect(links.map(\.targetSlug) == ["a", "b", "c"])
        #expect(links.allSatisfy { $0.line == 2 })
    }

    @Test
    func `links inside fenced code are ignored`() {
        let source = """
        [[real]]

        ```
        [[not-a-link]]
        ```

        [[alsoreal]]
        """
        #expect(Wikilinks.extract(from: source).map(\.targetSlug) == ["real", "alsoreal"])
    }

    @Test
    func `links inside inline code spans are ignored`() {
        let links = Wikilinks.extract(from: "type `[[literal]]` to make [[real]]")
        #expect(links.map(\.targetSlug) == ["real"])
    }

    @Test
    func `a same-document heading anchor is not an edge`() {
        // `[[#Section]]` points inside the current note, so it is not a link
        // between documents and must not create a graph edge.
        #expect(Wikilinks.extract(from: "jump to [[#Section]]").isEmpty)
    }

    @Test
    func `unterminated and empty brackets produce nothing`() {
        #expect(Wikilinks.extract(from: "open [[never closed").isEmpty)
        #expect(Wikilinks.extract(from: "[[]]").isEmpty)
        #expect(Wikilinks.extract(from: "[[   ]]").isEmpty)
    }

    @Test
    func `a single bracket pair is not a wikilink`() {
        #expect(Wikilinks.extract(from: "a [markdown](link) and [ref]").isEmpty)
    }

    @Test
    func `an absurdly long target is rejected rather than indexed`() {
        let long = String(repeating: "x", count: Wikilinks.maxTargetLength + 1)
        #expect(Wikilinks.extract(from: "[[\(long)]]").isEmpty)
    }

    @Test
    func `path spellings are normalized but case is preserved`() {
        #expect(Wikilinks.normalizeSlug("./Notes/A.md") == "Notes/A.md")
        #expect(Wikilinks.normalizeSlug("/Notes/A.md") == "Notes/A.md")
        #expect(Wikilinks.normalizeSlug("Notes\\A.md") == "Notes/A.md")
        // Lowercasing here would merge two distinct files on a case-sensitive
        // filesystem into one edge.
        #expect(Wikilinks.normalizeSlug("Notes/A.md") != Wikilinks.normalizeSlug("notes/a.md"))
    }
}

/// Two-tier resolution, and the refusal to guess.
struct WikilinkResolverTests {
    private func target(_ path: String) -> WikilinkTarget {
        WikilinkTarget(vaultFileID: UUID(), path: path)
    }

    private func link(_ inner: String) -> ParsedWikilink {
        Wikilinks.parse(inner, line: 1)!
    }

    @Test
    func `an exact path resolves`() {
        let hermes = target("projects/hermes.md")
        let resolved = WikilinkResolver.resolve(
            links: [link("projects/hermes")],
            candidates: [hermes, target("notes/other.md")]
        )
        #expect(resolved[0].state == .resolved)
        #expect(resolved[0].targetVaultFileID == hermes.vaultFileID)
    }

    @Test
    func `an exact path with its extension resolves`() {
        let hermes = target("projects/hermes.md")
        let resolved = WikilinkResolver.resolve(links: [link("projects/hermes.md")], candidates: [hermes])
        #expect(resolved[0].targetVaultFileID == hermes.vaultFileID)
    }

    @Test
    func `a unique filename stem resolves without a path`() {
        let hermes = target("deep/nested/hermes.md")
        let resolved = WikilinkResolver.resolve(
            links: [link("hermes")],
            candidates: [hermes, target("notes/unrelated.md")]
        )
        #expect(resolved[0].state == .resolved)
        #expect(resolved[0].targetVaultFileID == hermes.vaultFileID)
    }

    @Test
    func `a stem matching two documents is ambiguous, never guessed`() {
        let resolved = WikilinkResolver.resolve(
            links: [link("index")],
            candidates: [target("a/index.md"), target("b/index.md")]
        )
        #expect(resolved[0].state == .ambiguous)
        #expect(resolved[0].targetVaultFileID == nil, "an arbitrary pick would draw a wrong edge and cite a wrong file")
    }

    @Test
    func `an exact path wins over an ambiguous stem`() {
        let a = target("a/index.md")
        let resolved = WikilinkResolver.resolve(
            links: [link("a/index")],
            candidates: [a, target("b/index.md")]
        )
        #expect(resolved[0].state == .resolved)
        #expect(resolved[0].targetVaultFileID == a.vaultFileID)
    }

    @Test
    func `a link to nothing is unresolved`() {
        let resolved = WikilinkResolver.resolve(
            links: [link("does-not-exist")],
            candidates: [target("a.md")]
        )
        #expect(resolved[0].state == .unresolved)
        #expect(resolved[0].targetVaultFileID == nil)
    }

    @Test
    func `a heading fragment does not change which document is chosen`() {
        let hermes = target("projects/hermes.md")
        let withHeading = WikilinkResolver.resolve(links: [link("hermes#Fallbacks")], candidates: [hermes])
        let without = WikilinkResolver.resolve(links: [link("hermes")], candidates: [hermes])
        #expect(withHeading[0].targetVaultFileID == without[0].targetVaultFileID)
        #expect(withHeading[0].link.targetHeading == "Fallbacks")
    }

    @Test
    func `an alias does not change which document is chosen`() {
        let hermes = target("projects/hermes.md")
        let resolved = WikilinkResolver.resolve(links: [link("hermes|the router")], candidates: [hermes])
        #expect(resolved[0].targetVaultFileID == hermes.vaultFileID)
        #expect(resolved[0].link.label == "the router")
    }

    @Test
    func `longer suffixes are stripped before shorter ones`() {
        #expect(WikilinkResolver.stem(of: "a/note.markdown") == "note")
        #expect(WikilinkResolver.stem(of: "a/note.md") == "note")
        #expect(WikilinkResolver.stem(of: "a/note") == "note")
    }

    @Test
    func `resolution of an empty link list does no work`() {
        #expect(WikilinkResolver.resolve(links: [], candidates: [target("a.md")]).isEmpty)
    }
}
