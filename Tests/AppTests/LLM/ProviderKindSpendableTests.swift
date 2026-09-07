@testable import App
import Foundation
import Testing

/// A stored credential row only earns the BYO paywall exemption if a request
/// built from it could actually succeed.
///
/// The old test was `apiKey != nil || baseURL != nil`. Saving a bare base URL
/// against any provider therefore unlocked the paid surface, even though for
/// every provider that authenticates such a row cannot buy a single token.
struct ProviderKindSpendableTests {
    @Test
    func `a non-empty key is spendable for any provider`() {
        for kind in ProviderKind.userCredentialTargets {
            #expect(kind.isSpendable(apiKey: "sk-live", baseURL: nil), "\(kind) with a key")
        }
    }

    @Test
    func `an empty or absent key is not spendable`() {
        #expect(ProviderKind.openai.isSpendable(apiKey: "", baseURL: nil) == false)
        #expect(ProviderKind.openai.isSpendable(apiKey: nil, baseURL: nil) == false)
    }

    /// The bug: a base URL with no key, on a provider that authenticates.
    @Test
    func `a bare base URL does not unlock a provider that authenticates`() {
        let url = URL(string: "https://api.openai.com/v1")
        for kind in ProviderKind.userCredentialTargets.subtracting(ProviderKind.keylessCapable) {
            #expect(
                kind.isSpendable(apiKey: nil, baseURL: url) == false,
                "\(kind) has no keyless mode — a base URL alone proves nothing"
            )
        }
    }

    /// Ollama and a custom endpoint address a server the user runs, which
    /// commonly has no auth, so there the URL genuinely is the credential.
    @Test
    func `a base URL is the whole credential for a self-hosted endpoint`() {
        let url = URL(string: "http://100.105.117.67:11434")
        #expect(ProviderKind.ollama.isSpendable(apiKey: nil, baseURL: url))
        #expect(ProviderKind.custom.isSpendable(apiKey: nil, baseURL: url))
    }

    @Test
    func `a malformed base URL is not a credential`() {
        #expect(ProviderKind.ollama.isSpendable(apiKey: nil, baseURL: URL(string: "not a url")) == false)
        #expect(ProviderKind.ollama.isSpendable(apiKey: nil, baseURL: URL(string: "/just/a/path")) == false)
        #expect(ProviderKind.ollama.isSpendable(apiKey: nil, baseURL: nil) == false)
    }
}
