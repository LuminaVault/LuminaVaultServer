@testable import App
import Foundation
import Testing

struct HermesArtifactExtractorTests {
    @Test
    func `markdown image becomes an image artifact`() {
        let records = HermesArtifactExtractor.extract(
            sessionID: "s1",
            sessionTitle: "Sketch",
            sessionTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            messages: [
                HermesMirrorSessionMessage(
                    role: "assistant",
                    content: "Here you go: ![logo](https://cdn.example.com/logo.png)",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_100)
                ),
            ]
        )
        #expect(records.map(\.kind) == [.image])
        #expect(records.first?.value == "https://cdn.example.com/logo.png")
        #expect(records.first?.label == "logo.png")
        #expect(records.first?.sessionTitle == "Sketch")
    }

    @Test
    func `bare url becomes a link`() {
        let records = HermesArtifactExtractor.extract(
            sessionID: "s1",
            sessionTitle: "Research",
            sessionTimestamp: nil,
            messages: [
                HermesMirrorSessionMessage(
                    role: "assistant",
                    content: "Read https://docs.hermes-agent.dev/skills",
                    timestamp: nil
                ),
            ]
        )
        #expect(records.map(\.kind) == [.link])
        #expect(records.first?.value == "https://docs.hermes-agent.dev/skills")
    }

    @Test
    func `absolute path with an extension becomes a file`() {
        let records = HermesArtifactExtractor.extract(
            sessionID: "s1",
            sessionTitle: "Export",
            sessionTimestamp: nil,
            messages: [
                HermesMirrorSessionMessage(
                    role: "assistant",
                    content: "Wrote /home/hermes/.hermes/output/brief.md",
                    timestamp: nil
                ),
            ]
        )
        #expect(records.map(\.kind) == [.file])
        #expect(records.first?.value == "/home/hermes/.hermes/output/brief.md")
        #expect(records.first?.label == "brief.md")
    }

    @Test
    func `tool json path is harvested`() {
        let records = HermesArtifactExtractor.extract(
            sessionID: "s1",
            sessionTitle: "Tool",
            sessionTimestamp: nil,
            messages: [
                HermesMirrorSessionMessage(
                    role: "tool",
                    content: #"{"output":"/tmp/chart.png","ok":true}"#,
                    timestamp: nil
                ),
            ]
        )
        #expect(records.contains { $0.kind == .image && $0.value == "/tmp/chart.png" })
    }

    @Test
    func `user messages are ignored and duplicates collapse`() {
        let records = HermesArtifactExtractor.extract(
            sessionID: "s1",
            sessionTitle: "Dup",
            sessionTimestamp: nil,
            messages: [
                HermesMirrorSessionMessage(role: "user", content: "https://example.com/a.png", timestamp: nil),
                HermesMirrorSessionMessage(role: "assistant", content: "https://example.com/a.png once", timestamp: nil),
                HermesMirrorSessionMessage(role: "assistant", content: "https://example.com/a.png twice", timestamp: nil),
            ]
        )
        #expect(records.count == 1)
        #expect(records.first?.kind == .image)
    }

    @Test
    func `content hash is stable for the same triple`() {
        let a = HermesArtifactExtractor.hash(kind: .link, value: "https://x.test", sessionID: "s1")
        let b = HermesArtifactExtractor.hash(kind: .link, value: "https://x.test", sessionID: "s1")
        let c = HermesArtifactExtractor.hash(kind: .link, value: "https://x.test", sessionID: "s2")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64)
    }
}
