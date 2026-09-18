@testable import App
import Foundation
import Testing

@Suite("Hermes escalation policy")
struct HermesEscalationPolicyTests {
    private typealias Policy = HermesEscalationPolicy

    // MARK: - Mode outranks the classifier

    /// Opting out has to be absolute. A user who turned agent turns off must
    /// not get one because their wording happened to look imperative.
    @Test("off never escalates, however imperative the message")
    func offNeverEscalates() {
        for content in ["commit this", "deploy to prod", "delete the branch"] {
            #expect(
                Policy.decide(content: content, mode: .off, hermesAvailable: true) == .classicStream,
                "escalated despite mode .off for: \(content)"
            )
        }
    }

    @Test("force escalates even when the message reads as a question")
    func forceAlwaysEscalates() {
        for content in ["what is in my vault?", "", "tell me about swift"] {
            #expect(
                Policy.decide(content: content, mode: .force, hermesAvailable: true) == .hermesRun,
                "did not escalate despite mode .force for: \(content)"
            )
        }
    }

    /// Availability beats intent, including an explicit force. There is
    /// nothing to escalate to, and an ordinary answer beats an error.
    @Test("An unreachable Hermes falls back to the classic stream, even on force")
    func unavailableAlwaysFallsBack() {
        for mode in [Policy.Mode.off, .auto, .force] {
            #expect(
                Policy.decide(content: "commit this", mode: mode, hermesAvailable: false) == .classicStream,
                "escalated with Hermes unavailable in mode \(mode)"
            )
        }
    }

    // MARK: - auto classifier

    @Test("auto escalates a leading action verb")
    func autoEscalatesActions() {
        let messages = [
            "commit the staged changes",
            "deploy the api to staging",
            "refactor this into a service",
            "delete the merged branches",
            "please commit this",
            "could you deploy the api",
            "Fix the failing test",
        ]
        for content in messages {
            #expect(
                Policy.decide(content: content, mode: .auto, hermesAvailable: true) == .hermesRun,
                "did not escalate: \(content)"
            )
        }
    }

    @Test("auto leaves questions and statements on the classic stream")
    func autoLeavesQuestionsAlone() {
        let messages = [
            "what did I write about deployment last week?",
            "how does the commit flow work?",
            "summarise my notes on refactoring",
            "remind me why we deleted that",
            "",
            "   ",
        ]
        for content in messages {
            #expect(
                Policy.decide(content: content, mode: .auto, hermesAvailable: true) == .classicStream,
                "escalated: \(content)"
            )
        }
    }

    /// The verb has to lead. A message *about* deploying is not a message
    /// asking to deploy, and treating it as one would hand ordinary
    /// questions to a slower, costlier agent turn.
    @Test("An action verb mid-sentence does not escalate")
    func verbMustLead() {
        #expect(Policy.looksLikeAction("how does deploy work") == false)
        #expect(Policy.looksLikeAction("notes about commit hygiene") == false)
        #expect(Policy.looksLikeAction("deploy the thing"))
    }

    /// "run me through X" is the common false positive: an action verb that
    /// opens a request for explanation.
    @Test("'<verb> me ...' reads as a request for explanation")
    func verbFollowedByMeIsAQuestion() {
        #expect(Policy.looksLikeAction("run me through the auth flow") == false)
        #expect(Policy.looksLikeAction("walk me through this") == false)
        #expect(Policy.looksLikeAction("run the migration"))
    }

    @Test("Politeness prefixes are stripped before classifying")
    func politenessIsStripped() {
        #expect(Policy.looksLikeAction("please deploy"))
        #expect(Policy.looksLikeAction("hey, can you deploy the api"))
        #expect(Policy.looksLikeAction("okay please build it"))
    }

    @Test("Punctuation and capitalisation do not change the verdict")
    func tokenizationIsRobust() {
        #expect(Policy.looksLikeAction("COMMIT!"))
        #expect(Policy.looksLikeAction("  commit,  the changes"))
        #expect(Policy.looksLikeAction("Delete — the old branch"))
    }
}
