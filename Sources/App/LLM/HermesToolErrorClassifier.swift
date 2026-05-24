import Foundation
import Logging
import LuminaVaultShared
import Metrics

/// Categorised view of a single Hermes tool-call failure surfaced in the
/// assistant content stream. Used for structured logging + metrics today;
/// can be added to the wire `ChatResponse` once `LuminaVaultShared` is
/// bumped (CLAUDE.md §3 — wire DTOs live there).
struct ChatToolError: Equatable {
    enum Category: String {
        case notInstalled
        case permissionDenied
        case timeout
        case loopExhausted
        case other
    }

    let toolName: String
    let category: Category
    /// First line of the underlying error message — already sanitized for
    /// surface (no `/usr/bin/bash:` prefix, no absolute paths).
    let message: String
    let isRetryable: Bool
}

/// Inspects Hermes upstream assistant content for tool-failure warning
/// lines (`Tool X returned error`, `same_tool_failure_warning`, raw bash
/// stderr leaks) and:
///
/// 1. Returns a list of structured `ChatToolError`s for telemetry.
/// 2. Strips the stderr-shaped lines from the content string so users
///    never see `/usr/bin/bash: line 3: pip: command not found`.
///
/// The classifier is intentionally regex-driven and stateless — easy to
/// extend with new patterns when Hermes adds a new failure shape.
enum HermesToolErrorClassifier {
    /// Regex values are immutable and the literals here have no embedded
    /// captures with reference semantics — the values are safe to share
    /// across isolation domains. Swift 6 still flags them because
    /// `Regex<(Substring, Substring, Substring)>` does not auto-conform
    /// to `Sendable` (tuple-typed `Output` blocks the synthesised
    /// conformance). The `nonisolated(unsafe)` annotation is the
    /// documented escape hatch per CLAUDE.md §1.
    private nonisolated(unsafe) static let toolReturnedErrorRegex =
        #/Tool ([A-Za-z0-9_.-]+) returned error \(.*?\): (.+)/#
    private nonisolated(unsafe) static let loopWarningRegex =
        #/same_tool_failure_warning; count=(\d+); ([A-Za-z0-9_.-]+) has failed/#

    /// Patterns we always strip from user-facing content. Each line that
    /// matches any of these is removed (the surrounding lines are kept).
    /// Same `nonisolated(unsafe)` rationale as the regex literals above.
    private nonisolated(unsafe) static let stderrPatterns: [Regex<Substring>] = [
        try! Regex(#"/usr/bin/bash: line \d+: .*"#),
        try! Regex(#"/bin/bash: line \d+: .*"#),
        try! Regex(#"^.+?: command not found.*"#),
        try! Regex(#"^No such file or directory.*"#),
        try! Regex(#"^.*: No module named .*"#),
        try! Regex(#"^Errno \d+.*"#),
        try! Regex(#"^Traceback \(most recent call last\):.*"#),
    ]

    /// Classify any structured tool errors present in `content`.
    static func classify(content: String?) -> [ChatToolError] {
        guard let content, !content.isEmpty else { return [] }

        var errors: [ChatToolError] = []

        for match in content.matches(of: toolReturnedErrorRegex) {
            let toolName = String(match.output.1)
            let message = String(match.output.2).prefix(200)
            errors.append(
                ChatToolError(
                    toolName: toolName,
                    category: categorise(rawMessage: String(message)),
                    message: sanitizeSingleLine(String(message)),
                    isRetryable: false,
                ),
            )
        }

        for match in content.matches(of: loopWarningRegex) {
            let toolName = String(match.output.2)
            errors.append(
                ChatToolError(
                    toolName: toolName,
                    category: .loopExhausted,
                    message: "Tool failed repeatedly and was disabled for this turn.",
                    isRetryable: false,
                ),
            )
        }

        return errors
    }

    /// Strip stderr-shaped lines from `content` so they never reach the
    /// client. Returns `nil` if the result is empty or `content` was nil.
    static func sanitize(content: String?) -> String? {
        guard let content, !content.isEmpty else { return content }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            !stderrPatterns.contains { line.contains($0) }
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Convenience: sanitize the assistant `ChatMessage`'s content in place,
    /// returning a fresh `ChatMessage` with the same role / tool_calls.
    /// `ChatMessage.content` is non-optional on the wire, so an empty
    /// sanitization result collapses to the empty string.
    static func sanitize(message: ChatMessage) -> ChatMessage {
        ChatMessage(
            role: message.role,
            content: sanitize(content: message.content) ?? "",
            tool_calls: message.tool_calls,
        )
    }

    /// Emit structured log + metric events for each error. Caller chooses
    /// when to log (typically once per assistant turn).
    static func observe(
        errors: [ChatToolError],
        model: String,
        profile: String,
        logger: Logger,
    ) {
        for error in errors {
            logger.warning(
                """
                hermes.tool_failure tool=\(error.toolName) \
                category=\(error.category.rawValue) model=\(model) \
                profile=\(profile) retryable=\(error.isRetryable) \
                msg=\(error.message)
                """,
            )
            Counter(label: "luminavault.llm.tool_failure", dimensions: [
                ("tool", error.toolName),
                ("category", error.category.rawValue),
            ]).increment()
        }
    }

    // MARK: - Internal helpers

    private static func categorise(rawMessage: String) -> ChatToolError.Category {
        let m = rawMessage.lowercased()
        if m.contains("not installed") || m.contains("command not found")
            || m.contains("no such file or directory") || m.contains("no module named")
        {
            return .notInstalled
        }
        if m.contains("permission denied") || m.contains("eaccess") {
            return .permissionDenied
        }
        if m.contains("timed out") || m.contains("timeout") || m.contains("etimedout") {
            return .timeout
        }
        return .other
    }

    /// Trim trailing whitespace / newlines and collapse internal newlines.
    private static func sanitizeSingleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
