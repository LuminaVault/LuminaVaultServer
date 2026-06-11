@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// HER-37 Slice C — unit tests for `FollowUpGenerator`. The generator
/// hits Hermes through a stubbed `HermesChatTransport` so the tests run
/// without Postgres or a live LLM. Every path is exercised because the
/// generator is the only Slice C touchpoint surfaced to clients.
struct FollowUpGeneratorTests {
    // MARK: - Happy path

    @Test
    func `parses JSON follow-up array from upstream assistant message`() async {
        let transport = StubFollowUpTransport(plainContent: """
        {"follow_ups": ["Go deeper", "Compare with last month", "Save as memo"]}
        """)
        let generator = makeGenerator(transport: transport)
        let out = await generator.generate(
            sessionKey: "ferocious-fox",
            summary: "You slept 8h this week.",
            sources: [Self.hit("slept 9h Tuesday")]
        )
        #expect(out == ["Go deeper", "Compare with last month", "Save as memo"])
    }

    @Test
    func `caps output at maxFollowUps soft ceiling`() async {
        let transport = StubFollowUpTransport(plainContent: """
        {"follow_ups": ["a","b","c","d","e","f","g"]}
        """)
        let generator = makeGenerator(transport: transport, max: 3)
        let out = await generator.generate(
            sessionKey: "u",
            summary: "s",
            sources: [Self.hit("hit")]
        )
        #expect(out.count == 3)
        #expect(out == ["a", "b", "c"])
    }

    @Test
    func `trims whitespace and drops empty entries`() async {
        let transport = StubFollowUpTransport(plainContent: """
        {"follow_ups": ["  Go deeper ", "", "   ", "Save"]}
        """)
        let generator = makeGenerator(transport: transport)
        let out = await generator.generate(sessionKey: "u", summary: "s", sources: [])
        #expect(out == ["Go deeper", "Save"])
    }

    // MARK: - Defensive failures

    @Test
    func `returns empty array on transport failure`() async {
        let transport = StubFollowUpTransport(error: TestError.upstream)
        let generator = makeGenerator(transport: transport)
        let out = await generator.generate(
            sessionKey: "u",
            summary: "s",
            sources: [Self.hit("h")]
        )
        #expect(out.isEmpty)
    }

    @Test
    func `returns empty array on malformed assistant JSON`() async {
        let transport = StubFollowUpTransport(plainContent: "not json at all")
        let generator = makeGenerator(transport: transport)
        let out = await generator.generate(sessionKey: "u", summary: "s", sources: [])
        #expect(out.isEmpty)
    }

    @Test
    func `returns empty array on empty assistant content`() async {
        let transport = StubFollowUpTransport(plainContent: "")
        let generator = makeGenerator(transport: transport)
        let out = await generator.generate(sessionKey: "u", summary: "s", sources: [])
        #expect(out.isEmpty)
    }

    @Test
    func `short-circuits without an upstream call when summary and sources are empty`() async {
        let transport = StubFollowUpTransport(plainContent: """
        {"follow_ups": ["should not appear"]}
        """)
        let generator = makeGenerator(transport: transport)
        let out = await generator.generate(sessionKey: "u", summary: "   ", sources: [])
        #expect(out.isEmpty)
        let calls = await transport.callCount
        #expect(calls == 0)
    }

    // MARK: - Prompt construction

    @Test
    func `buildPrompt truncates long source contents to keep tokens bounded`() {
        let long = String(repeating: "a", count: 500)
        let messages = FollowUpGenerator.buildPrompt(
            summary: "s",
            sources: [Self.hit(long)],
            max: 4
        )
        #expect(messages.count == 2)
        // User message contains numbered context with truncated content.
        let user = messages[1].content
        #expect(user.contains("[1]"))
        #expect(user.contains(String(repeating: "a", count: 120)))
        #expect(!user.contains(String(repeating: "a", count: 121)))
    }

    @Test
    func `buildPrompt with no sources still produces a valid prompt`() {
        let messages = FollowUpGenerator.buildPrompt(summary: "summary", sources: [], max: 4)
        #expect(messages.count == 2)
        #expect(messages[1].content.contains("no source notes"))
    }

    // MARK: - Helpers

    private func makeGenerator(transport: StubFollowUpTransport, max: Int = 4) -> FollowUpGenerator {
        FollowUpGenerator(
            transport: transport,
            defaultModel: "test-model",
            logger: Logger(label: "test.followups"),
            maxFollowUps: max
        )
    }

    private static func hit(_ content: String) -> QueryHitDTO {
        QueryHitDTO(id: UUID(), content: content, distance: 0.1, createdAt: nil)
    }
}

// MARK: - Test transport

/// Minimal `HermesChatTransport` stub that returns a canned chat
/// completion (with assistant content) or throws a fixed error. Tracks
/// call count so tests can assert the short-circuit path.
private actor StubFollowUpTransport: HermesChatTransport {
    private let response: Result<String, Error>
    private(set) var callCount: Int = 0

    init(plainContent: String) {
        response = .success(plainContent)
    }

    init(error: Error) {
        response = .failure(error)
    }

    nonisolated func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        try await record()
    }

    private func record() throws -> Data {
        callCount += 1
        switch response {
        case let .failure(error):
            throw error
        case let .success(content):
            let body: [String: Any] = [
                "id": "test",
                "model": "test",
                "choices": [
                    [
                        "index": 0,
                        "finish_reason": "stop",
                        "message": [
                            "role": "assistant",
                            "content": content,
                        ],
                    ],
                ],
            ]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
    }
}

private enum TestError: Error {
    case upstream
}
