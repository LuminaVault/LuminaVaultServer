import Foundation

/// Decides whether a chat turn is answered by the ordinary
/// retrieval-augmented stream or handed to a Hermes agent run.
///
/// Kept as a pure function with no I/O so the decision can be tested
/// exhaustively without a database, a Hermes container or a live stream. The
/// caller supplies the facts; this decides.
///
/// The decision is the server's, never the client's. Clients do not call
/// `POST /v1/hermes/runs` from the composer — if they did there would be two
/// ways to start a turn, two places to enforce entitlements and rate limits,
/// and two code paths to keep in step.
enum HermesEscalationPolicy {
    /// What the caller asked for. Mirrors `ChatAgentModeDTO` on the wire.
    enum Mode: String, Sendable {
        /// Never escalate. The user has opted out of agent turns.
        case off
        /// Let the classifier decide. The default.
        case auto
        /// Always escalate, subject only to Hermes being reachable.
        case force
    }

    enum Decision: Equatable, Sendable {
        case classicStream
        case hermesRun
    }

    /// Verbs that mean "go and do something", as opposed to "tell me
    /// something". Retrieval answers the second kind well and cannot serve
    /// the first at all, which is the line escalation is drawn on.
    ///
    /// Deliberately small and boring. A wrong escalation costs a slower,
    /// pricier turn; a wrong non-escalation just gives the ordinary answer.
    /// Both are recoverable, so the bar for adding a verb here is that it
    /// almost always implies acting on the world.
    private static let actionVerbs: Set<String> = [
        "commit", "deploy", "install", "run", "execute", "build",
        "create", "write", "edit", "rename", "delete", "remove",
        "refactor", "fix", "patch", "migrate", "rebase", "merge",
        "push", "publish", "release", "schedule", "automate",
    ]

    static func decide(
        content: String,
        mode: Mode,
        hermesAvailable: Bool
    ) -> Decision {
        // Availability outranks intent. If Hermes cannot be reached there is
        // nothing to escalate to, and a classic answer beats an error — even
        // when the user explicitly forced an agent turn.
        guard hermesAvailable else { return .classicStream }

        switch mode {
        case .off:
            return .classicStream
        case .force:
            return .hermesRun
        case .auto:
            return looksLikeAction(content) ? .hermesRun : .classicStream
        }
    }

    /// True when the message opens with an action verb, optionally behind a
    /// polite prefix. Anchored to the start rather than searched anywhere in
    /// the text, because "how does deploy work" is a question about doing,
    /// not a request to do.
    static func looksLikeAction(_ content: String) -> Bool {
        var words = content
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)

        // Strip a leading politeness so "please commit this" reads the same
        // as "commit this".
        let politePrefixes: Set<String> = ["please", "could", "can", "would", "you", "hey", "ok", "okay"]
        while let first = words.first, politePrefixes.contains(first) {
            words.removeFirst()
        }

        guard let verb = words.first else { return false }

        // A question is a question even when it starts with an action verb:
        // "run" in "run me through the auth flow" is not a request to run
        // anything. Cheap guard, catches the common phrasing.
        if words.count > 1, words[1] == "me" { return false }

        return actionVerbs.contains(verb)
    }
}
