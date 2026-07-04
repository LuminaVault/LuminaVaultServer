import Foundation
import LuminaVaultShared

/// Default `SOUL.md` body written into a brand-new user's vault on signup
/// (HER-86). Hermes reads `SOUL.md` on every chat turn — every user must
/// have one before the first request, otherwise Hermes replies in default
/// voice and the privacy-first / personal-AI pitch breaks.
///
/// Since template v2 this is a thin delegate: the canonical default is the
/// composer rendered with all-nil inputs, so signup, `DELETE /v1/soul`
/// (reset), and onboarding compose all share one template shape — including
/// the locked `SOULCore` covenant.
enum SOULDefaultTemplate {
    static func render(username: String, now: Date = Date()) -> String {
        SOULComposer.render(.defaults, username: username, now: now)
    }
}
