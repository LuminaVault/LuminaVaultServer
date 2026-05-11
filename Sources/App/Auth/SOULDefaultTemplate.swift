import Foundation

/// Default `SOUL.md` body written into a brand-new user's vault on signup
/// (HER-86). Documents tone, priorities, and learning style as placeholders
/// that the iOS onboarding personality-quiz overwrites step by step
/// (see HER-100). Hermes reads `SOUL.md` on every chat turn — every user
/// must have one before the first request, otherwise Hermes replies in
/// default voice and the privacy-first / personal-AI pitch breaks.
enum SOULDefaultTemplate {
    static let version = 1

    /// Renders the default template with the user's username substituted in
    /// the greeting. Other fields are left as TODO placeholders — onboarding
    /// fills them in via PATCH operations against the SOUL.md endpoints.
    static func render(username: String, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter().string(from: now)
        return """
        ---
        version: \(version)
        username: \(username)
        created_at: \(iso)
        ---

        # SOUL.md

        Hermes reads this file on every reply. Tone, priorities, and learning
        style live here. Onboarding (HER-100) fills the placeholders in; you
        can also edit this file directly via the iOS settings screen.

        ## Tone preferences

        - Voice: <!-- e.g. "warm but direct", "playful", "stoic" -->
        - Formality: <!-- "casual" | "neutral" | "formal" -->
        - Emoji usage: <!-- "none" | "sparing" | "expressive" -->
        - Pet phrases to avoid: <!-- e.g. "circle back", "let's unpack" -->

        ## Priorities

        - Top goals: <!-- 2-3 outcomes I'm working toward this quarter -->
        - Recurring topics: <!-- domains I care about: health, money, family, … -->
        - Hard "no"s: <!-- things I never want surfaced -->

        ## Learning style

        - I retain best via: <!-- "stories" | "tables" | "examples" | "first principles" -->
        - Pace: <!-- "fast scan" | "deep dive" | "depends on topic" -->
        - When I push back, do: <!-- "double down" | "reframe" | "drop it" -->

        ## Identity & context

        - Pronouns: <!-- e.g. "she/her" -->
        - Time zone: <!-- e.g. "Europe/Lisbon" -->
        - Languages I think in: <!-- comma-separated -->

        <!-- Hermes: anything below this line is free-form notes the user wrote about themselves. -->
        """
    }
}
