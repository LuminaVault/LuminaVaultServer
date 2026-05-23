@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Golden-table coverage of `HermesToolErrorClassifier`. The classifier
/// sits on every chat response path, so each pattern + sanitization rule
/// gets a pinned test.
struct HermesToolErrorClassifierTests {

    // MARK: - classify(content:)

    @Test
    func `tool returned error parses tool name and message`() {
        let raw = """
        Working on it…
        Tool terminal returned error (0.23s): {"output": "/usr/bin/bash: line 3: pip: command not found", "exit_code": 127, "error": null}
        """
        let errors = HermesToolErrorClassifier.classify(content: raw)
        #expect(errors.count == 1)
        #expect(errors.first?.toolName == "terminal")
        #expect(errors.first?.category == .notInstalled)
        #expect(errors.first?.isRetryable == false)
    }

    @Test
    func `same_tool_failure_warning parses loop exhausted`() {
        let raw = """
        [Tool loop warning: same_tool_failure_warning; count=3; terminal has failed 3 times this turn]
        """
        let errors = HermesToolErrorClassifier.classify(content: raw)
        #expect(errors.count == 1)
        #expect(errors.first?.toolName == "terminal")
        #expect(errors.first?.category == .loopExhausted)
    }

    @Test
    func `youtube-transcript-api missing maps to notInstalled`() {
        let raw = #"Tool terminal returned error (0.50s): {"output": "Error: youtube-transcript-api not installed. Run: pip install youtube-transcript-api", "exit_code": 1}"#
        let errors = HermesToolErrorClassifier.classify(content: raw)
        #expect(errors.first?.category == .notInstalled)
    }

    @Test
    func `tirith spawn error maps to notInstalled`() {
        // `tirith spawn failed: [Errno 2] No such file or directory: 'tirith'`
        let raw = "Tool tirith_security returned error (0.10s): tirith spawn failed: [Errno 2] No such file or directory: 'tirith'"
        let errors = HermesToolErrorClassifier.classify(content: raw)
        #expect(errors.first?.category == .notInstalled)
    }

    @Test
    func `timeout error maps to timeout category`() {
        let raw = "Tool web_search returned error (30.0s): request timed out after 30s"
        let errors = HermesToolErrorClassifier.classify(content: raw)
        #expect(errors.first?.category == .timeout)
    }

    @Test
    func `permission denied maps to permissionDenied`() {
        let raw = "Tool file_write returned error (0.01s): EACCES: permission denied, open '/etc/hosts'"
        let errors = HermesToolErrorClassifier.classify(content: raw)
        #expect(errors.first?.category == .permissionDenied)
    }

    @Test
    func `empty content returns empty array`() {
        #expect(HermesToolErrorClassifier.classify(content: nil).isEmpty)
        #expect(HermesToolErrorClassifier.classify(content: "").isEmpty)
    }

    @Test
    func `clean assistant content returns empty array`() {
        let raw = "Hi! I'd suggest reviewing your notes from last week."
        #expect(HermesToolErrorClassifier.classify(content: raw).isEmpty)
    }

    // MARK: - sanitize(content:)

    @Test
    func `bash stderr line is stripped`() {
        let raw = """
        Trying that now.
        /usr/bin/bash: line 3: pip: command not found
        I'll fall back to a manual approach.
        """
        let out = HermesToolErrorClassifier.sanitize(content: raw)
        #expect(out?.contains("/usr/bin/bash") == false)
        #expect(out?.contains("Trying that now.") == true)
        #expect(out?.contains("manual approach") == true)
    }

    @Test
    func `python no module named line is stripped`() {
        let raw = """
        Running setup.
        /opt/hermes/.venv/bin/python: No module named pip
        Let me try another tool.
        """
        let out = HermesToolErrorClassifier.sanitize(content: raw)
        #expect(out?.contains("No module named pip") == false)
        #expect(out?.contains("Let me try another tool.") == true)
    }

    @Test
    func `multiple stderr lines all stripped`() {
        let raw = """
        Hello.
        /usr/bin/bash: line 1: pip: command not found
        /usr/bin/bash: line 2: pip3: command not found
        Done.
        """
        let out = HermesToolErrorClassifier.sanitize(content: raw)
        #expect(out?.contains("command not found") == false)
        #expect(out?.contains("Hello.") == true)
        #expect(out?.contains("Done.") == true)
    }

    @Test
    func `sanitize collapses to nil when content was only noise`() {
        let raw = """
        /usr/bin/bash: line 1: pip: command not found
        /usr/bin/bash: line 2: pip: command not found
        """
        #expect(HermesToolErrorClassifier.sanitize(content: raw) == nil)
    }

    @Test
    func `sanitize preserves nil and empty inputs`() {
        #expect(HermesToolErrorClassifier.sanitize(content: nil) == nil)
        #expect(HermesToolErrorClassifier.sanitize(content: "") == "")
    }

    // MARK: - sanitize(message:)

    @Test
    func `sanitize message keeps role and tool_calls`() {
        let dirty = ChatMessage(
            role: "assistant",
            content: """
            Working on it.
            /usr/bin/bash: line 1: pip: command not found
            Done.
            """,
            tool_calls: [
                ChatToolCall(
                    id: "call_1",
                    type: "function",
                    function: ChatToolCallFunction(name: "search", arguments: "{}"),
                ),
            ],
        )
        let clean = HermesToolErrorClassifier.sanitize(message: dirty)
        #expect(clean.role == "assistant")
        #expect(clean.tool_calls?.first?.id == "call_1")
        #expect(clean.content.contains("/usr/bin/bash") == false)
        #expect(clean.content.contains("Done.") == true)
    }

    @Test
    func `sanitize message collapses empty content to empty string`() {
        let dirty = ChatMessage(
            role: "assistant",
            content: "/usr/bin/bash: line 1: pip: command not found",
            tool_calls: nil,
        )
        let clean = HermesToolErrorClassifier.sanitize(message: dirty)
        #expect(clean.content == "")
    }
}
