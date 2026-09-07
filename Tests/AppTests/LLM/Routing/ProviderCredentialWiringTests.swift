@testable import App
import Foundation
import Logging
import Testing

/// Every provider whose key the UI offers to store must have an adapter that
/// can actually spend it.
///
/// `GeminiContentsAdapter` supported BYOK completely — the parameter, the
/// resolution, the fail-closed path — and `App+build` constructed it without
/// the credential store. `.gemini` is in `userCredentialTargets`, so the
/// providers pane took a key that the router structurally could not read, and
/// every `.byok` Gemini request threw `BYOKKeysRequiredError` against a
/// perfectly good stored key. Nothing failed loudly: each half looked right on
/// its own.
struct ProviderCredentialWiringTests {
    private static let logger = Logger(label: "test.provider-wiring")

    private static func store() -> UserCredentialStore? {
        // A non-nil store is all `acceptsUserCredentials` reports on; the
        // adapters are not asked to resolve anything here.
        nil
    }

    /// Constructs each adapter exactly as `App+build` does, with a store.
    private static func byoCapableAdapters(store: UserCredentialStore?) -> [any ProviderAdapter] {
        var adapters: [any ProviderAdapter] = [
            GeminiContentsAdapter(apiKey: "", logger: logger, userCredentials: store),
            AnthropicAdapter(
                apiKey: "",
                baseURL: URL(string: "https://api.anthropic.com")!,
                logger: logger,
                userCredentials: store
            ),
            OllamaAdapter(
                defaultBaseURL: URL(string: "http://localhost:11434")!,
                logger: logger,
                userCredentials: store
            ),
        ]
        for kind in [ProviderKind.xai, .openai, .openRouter, .nous, .nvidia, .custom] {
            adapters.append(OpenAICompatibleAdapter(
                kind: kind,
                apiKey: "",
                baseURL: OpenAICompatibleAdapter.defaultBaseURL(for: kind),
                logger: logger,
                userCredentials: store
            ))
        }
        return adapters
    }

    /// The invariant that was violated: the set of kinds the UI collects keys
    /// for must be covered by adapters built with the credential store.
    @Test
    func `every user-credential target has a BYO-capable adapter`() {
        let covered = Set(Self.byoCapableAdapters(store: nil).map(\.kind))
        let missing = ProviderKind.userCredentialTargets.subtracting(covered)
        #expect(
            missing.isEmpty,
            "these providers accept a user key with no adapter to spend it: \(missing.map(\.rawValue).sorted())"
        )
    }

    /// An adapter built without a store must say so, or the flag is useless
    /// as a wiring check.
    @Test
    func `an adapter with no store does not claim to accept user credentials`() {
        for adapter in Self.byoCapableAdapters(store: nil) {
            #expect(
                adapter.acceptsUserCredentials == false,
                "\(adapter.kind) reported credential support without a store"
            )
        }
    }

    /// Platform-key-only adapters keep the protocol default.
    @Test
    func `a platform-only adapter reports no credential support`() {
        let groq = OpenAICompatibleAdapter(
            kind: .groq,
            apiKey: "platform-key",
            baseURL: OpenAICompatibleAdapter.defaultBaseURL(for: .groq),
            logger: Self.logger
        )
        #expect(groq.acceptsUserCredentials == false)
    }
}
