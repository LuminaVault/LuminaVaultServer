import Foundation
import LuminaVaultShared

/// Why a request was pushed onto the free lane.
enum FreeLaneTrigger: String, Sendable, Equatable, Codable {
    /// The user's effective tier does not entitle them to paid managed
    /// inference, and they have not brought a key. The ordinary case.
    case notEntitled
    /// Platform-funded managed inference is unavailable or exhausted. The
    /// emergency case — it degrades even paying users, and should be alerted on.
    case platformUnavailable
}

struct FreeLaneVerdict: Sendable, Equatable {
    let trigger: FreeLaneTrigger
    /// The free lane is the only legal route; stored user preference is ignored
    /// for this request (but never overwritten).
    let forced: Bool
}

/// The single statement of who pays for a request.
///
/// **Paying (`pro`/`ultimate`, including `tier_override`) or BYOK-with-a-real-key
/// ⇒ the user's own choice is honoured. Everyone else ⇒ free lane.**
///
/// Pure: no Fluent, no Hummingbird, no I/O. It exists as its own type so the
/// matrix can be tested exhaustively without a database, and so there is exactly
/// one place to read when the question is "why did this user get that model".
enum FreeLanePolicy {
    struct Input: Sendable {
        /// `EntitlementChecker.effectiveTier(tier:override:)` — already folds in
        /// `tier_override`, so an ops-granted Pro is indistinguishable from a
        /// paid one here, which is what we want.
        let effectiveTier: UserTier
        let requestedMode: LLMBrainMode
        /// Any credential row the router could actually spend
        /// (`CerberusModelRouter.credentialedProviderIDs` non-empty).
        let hasUsableUserCredential: Bool
        /// Platform paid managed inference is funded and registered
        /// (`ProviderRegistry.isEnabled(.openRouter)`).
        let platformPaidManagedAvailable: Bool
        /// `freelane.enabled` kill switch.
        let freeLaneEnabled: Bool

        init(
            effectiveTier: UserTier,
            requestedMode: LLMBrainMode,
            hasUsableUserCredential: Bool,
            platformPaidManagedAvailable: Bool,
            freeLaneEnabled: Bool
        ) {
            self.effectiveTier = effectiveTier
            self.requestedMode = requestedMode
            self.hasUsableUserCredential = hasUsableUserCredential
            self.platformPaidManagedAvailable = platformPaidManagedAvailable
            self.freeLaneEnabled = freeLaneEnabled
        }
    }

    /// `nil` ⇒ honour the user's own choice; the caller routes normally.
    static func evaluate(_ input: Input) -> FreeLaneVerdict? {
        guard input.freeLaneEnabled else { return nil }

        // 1. BYOK with a real key: the user is paying their own provider.
        //    Honoured on every tier, including lapsed — we are not the ones
        //    being billed, so there is nothing to protect.
        if input.requestedMode == .byok, input.hasUsableUserCredential {
            return nil
        }

        // 2. Archived is read-only. `EntitlementMiddleware` 402s before routing
        //    ever happens; manufacturing a route here would only mask that.
        if input.effectiveTier == .archived {
            return nil
        }

        // 2b. BYOK selected but no key exists on any provider. This used to fall
        //     through to the tier switch below and, for an entitled user, end at
        //     a 403 `byok_keys_required` — the "I picked BYOK and now nothing
        //     works" dead end. A working free answer beats a dead end. The
        //     stored preference is read, never overwritten, so the moment a key
        //     is added rule 1 takes over again.
        //
        //     Deliberately placed *after* the archived guard: archived is 402'd
        //     upstream and must not get a manufactured route.
        if input.requestedMode == .byok, !input.hasUsableUserCredential {
            return FreeLaneVerdict(trigger: .notEntitled, forced: true)
        }

        // 3. Paying, and trial (card on file, 14-day funnel — real quality is
        //    the product being sold). Honoured unless the platform lane is gone,
        //    in which case the free lane is an emergency backstop rather than a
        //    downgrade, and the trigger says so.
        switch input.effectiveTier {
        case .pro, .ultimate, .trial:
            return input.platformPaidManagedAvailable
                ? nil
                : FreeLaneVerdict(trigger: .platformUnavailable, forced: true)
        case .free, .lapsed, .archived:
            break
        }

        // 4. Free and lapsed: never paid, or stopped paying. The forced lane.
        //    Note rule 1 ran first, so a free user who brought a real key keeps
        //    their own models on their own dime — the lane is for the people we
        //    would otherwise be buying tokens for.
        //    (BYOK-with-zero-keys is handled by rule 2b above, for every tier.)
        return FreeLaneVerdict(trigger: .notEntitled, forced: true)
    }

    /// Read-side counterpart, for surfaces that report the *effective* route
    /// rather than the stored preference.
    static func honoursUserChoice(_ input: Input) -> Bool {
        evaluate(input) == nil
    }
}
