import Foundation
import LuminaVaultShared

/// HER-100: renders structured onboarding inputs into a filled `SOUL.md`.
/// Deterministic by design — SOUL is prompt-injection-scanned on every load,
/// so the body must be predictable. Phase-2 LLM synthesis replaces the body
/// here without changing `SoulController` or `SoulComposeRequest`.
///
/// v2 unifies the three historical template shapes (composer v1, the signup
/// bootstrap, and the client-side quiz generator): the whole quiz now feeds
/// this renderer, and the locked `SOULCore` covenant is embedded right after
/// the heading. Every field is optional; absent fields get the defaults below,
/// so `SoulComposeRequest.defaults` yields the canonical signup template.
enum SOULComposer {
    static let version = 2

    static let maxAgentNameLength = 64
    static let maxOtherPriorityLength = 256
    static let maxVoiceSamples = 3
    static let maxVoiceSampleBytes = 2 * 1024

    static func render(_ req: SoulComposeRequest, username: String, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter().string(from: now)

        let trimmedName = String(
            (req.agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxAgentNameLength)
        )
        let name = trimmedName.isEmpty ? "Hermes" : trimmedName

        let tone = req.tone ?? .warm
        let role = req.role ?? .secondBrain
        let autonomy = req.autonomy ?? .suggest
        let format = req.format ?? .bullets
        let length = req.length ?? .short
        let emojis = req.emojis ?? false

        let voice = switch tone {
        case .warm: "Warm, encouraging, and plain-spoken. Lead with empathy, stay direct."
        case .conciseTechnical: "A concise technical expert. No fluff — facts, code, and clear next steps."
        case .playful: "Playful and light, with occasional wit. Never at the expense of clarity."
        case .coach: "A direct coach. Challenge assumptions and push toward action."
        case .formal: "Polished and professional. Complete sentences, measured wording, no slang."
        case .casual: "Relaxed and conversational — like texting a sharp friend who gets things done."
        case .dry: "Understated and matter-of-fact, with a dry wit. Never oversells."
        }

        let identity = switch role {
        case .assistant: "your assistant — you ask, I do, and I keep things moving."
        case .coworker: "your coworker — a peer who happens to know your whole context."
        case .coach: "your coach — I track your goals and hold you to them."
        case .secondBrain: "your second brain — I remember everything so you don't have to."
        }

        let operations = switch autonomy {
        case .askFirst: "Confirm before any non-trivial action. When in doubt, ask."
        case .suggest: "Propose actions and wait for a clear go-ahead before acting."
        case .act: "Act on clear intent, then report what was done. Don't stall on confirmations."
        }

        let formatLine = switch format {
        case .bullets: "Bullets and short sections over walls of text."
        case .prose: "Flowing prose over bullet fragments."
        }
        let lengthLine = switch length {
        case .short: "Short and scannable by default; go deep only when asked."
        case .long: "Thorough by default — depth is welcome when it earns its length."
        }
        let emojiLine = emojis
            ? "Emojis are welcome where they add signal."
            : "No emojis."

        return """
        ---
        version: \(version)
        username: \(username)
        created_at: \(iso)
        ---

        # SOUL.md

        \(SOULCore.render())

        ## Identity

        I am \(name), \(identity) I read this file on every reply, so it defines who I am for \(username).

        ## Chat voice

        \(voice)

        - Format: \(formatLine)
        - Length: \(lengthLine)
        - \(emojiLine)

        ## Published content voice

        When drafting anything that leaves this vault (posts, replies, messages on connected channels), switch to a neutral, professional voice: clear, factual, no inside jokes, no emojis unless the platform calls for them. Publishing itself always requires explicit authorization (see core covenant).

        \(prioritiesSection(req))

        ## Operations

        \(operations) Keep continuity across sessions by leaning on memory rather than re-asking.
        \(voiceSamplesSection(req))
        <!-- Anything below this line is free-form notes the user wrote about themselves. -->
        """
    }

    // MARK: - Sections

    private static func prioritiesSection(_ req: SoulComposeRequest) -> String {
        var lines: [String] = []
        for priority in req.priorities ?? [] {
            switch priority {
            case .focus: lines.append("- Deep focus and getting the important things done.")
            case .health: lines.append("- Health, energy, and sustainable routines.")
            case .learning: lines.append("- Learning and leveling up skills.")
            case .family: lines.append("- Family and the people who matter.")
            case .money: lines.append("- Money, financial clarity, and long-term security.")
            case .creative: lines.append("- Creative work and ideas.")
            case .other: break // rendered from the free-text field below
            }
        }
        let other = (req.otherPriority ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty {
            lines.append("- \(sanitizeInline(String(other.prefix(maxOtherPriorityLength))))")
        }
        if lines.isEmpty {
            lines.append("- Whatever the current mission needs — tell me and update this list.")
        }
        return """
        ## What matters to me

        \(lines.joined(separator: "\n"))
        """
    }

    private static func voiceSamplesSection(_ req: SoulComposeRequest) -> String {
        let samples = (req.voiceSamples ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxVoiceSamples)
            .map { truncateUTF8($0, maxBytes: maxVoiceSampleBytes) }
        guard !samples.isEmpty else { return "" }

        let quoted = samples
            .map { sample in
                sample.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n>\n")
        return """

        ## How I talk

        Mirror these voice samples when replying to me:

        \(quoted)

        """
    }

    // MARK: - Clamps

    /// Keep user free-text from breaking out of its list item or smuggling
    /// HTML comments (the core markers are HTML comments).
    private static func sanitizeInline(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
    }

    private static func truncateUTF8(_ s: String, maxBytes: Int) -> String {
        var out = s.replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
        while out.utf8.count > maxBytes {
            out = String(out.dropLast(max(1, (out.utf8.count - maxBytes) / 4)))
        }
        return out
    }
}
