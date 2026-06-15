@testable import App
import Foundation
import Logging
import Testing

/// Live integration test for the NVIDIA NIM provider path.
///
/// Exercises the *shipped* `OpenAICompatibleAdapter(kind: .nvidia)` against
/// the real endpoint (`https://integrate.api.nvidia.com/v1/chat/completions`).
/// Opt-in: the API key is read from the **`NVIDIA_API_KEY`** environment
/// variable and the test **skips itself when that is unset** — so CI without a
/// key stays green and no secret is ever committed.
///
/// Run locally with:
///   NVIDIA_API_KEY=nvapi-... swift test --filter NvidiaNIMLiveTests
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct NvidiaNIMLiveTests {
    private static var apiKey: String? {
        guard let key = ProcessInfo.processInfo.environment["NVIDIA_API_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return key
    }

    /// Minimal decode of the OpenAI chat-completions response.
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }

        let choices: [Choice]
    }

    @Test
    func `nvidia NIM adapter returns a completion`() async throws {
        guard let key = Self.apiKey else {
            // Skipped: no NVIDIA_API_KEY in the environment.
            return
        }

        let adapter = OpenAICompatibleAdapter(
            kind: .nvidia,
            apiKey: key,
            baseURL: OpenAICompatibleAdapter.defaultBaseURL(for: .nvidia),
            logger: Logger(label: "test.nvidia-nim")
        )

        let payload = try JSONSerialization.data(withJSONObject: [
            "model": "meta/llama-3.1-8b-instruct",
            "messages": [["role": "user", "content": "reply with the single word: pong"]],
            "max_tokens": 8,
            "temperature": 0,
        ])

        let data = try await adapter.chatCompletions(
            payload: payload,
            sessionKey: "nvidia-live-test",
            sessionID: nil
        )

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = try #require(decoded.choices.first?.message.content)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test
    func `nvidia default base URL is the NIM integrate host`() {
        let url = OpenAICompatibleAdapter.defaultBaseURL(for: .nvidia)
        #expect(url.absoluteString == "https://integrate.api.nvidia.com")
    }
}
