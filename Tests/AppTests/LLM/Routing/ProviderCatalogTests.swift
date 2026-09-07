@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// The static per-provider facts a BYO key form needs.
///
/// These were hardcoded in the iOS and web clients, so adding a provider
/// touched three repositories and the copies drifted — a client could offer a
/// base-URL field for a provider that ignores one, or show a provider as
/// unavailable that the router could happily spend.
struct ProviderCatalogTests {
    /// Every provider the user can store a key for must have an entry, or the
    /// form has nothing to render.
    @Test
    func `every provider has a catalog entry`() {
        let entries = ProviderCatalog.all()
        #expect(entries.count == ProviderID.allCases.count)
        #expect(Set(entries.map(\.provider)) == Set(ProviderID.allCases))
        for entry in entries {
            #expect(entry.displayName.isEmpty == false, "\(entry.provider) has no display name")
        }
    }

    /// A provider that authenticates must advertise a key requirement, or the
    /// form lets a user save a row that cannot buy a single token — the same
    /// class of unusable credential `ProviderKind.isSpendable` rejects.
    @Test
    func `providers that authenticate require a key`() {
        for id in [ProviderID.xai, .anthropic, .openai, .openRouter, .nvidia, .gemini, .nous] {
            let entry = ProviderCatalog.entry(for: id)
            #expect(entry.requiresAPIKey, "\(id) authenticates and must ask for a key")
            #expect(entry.defaultBaseURL != nil, "\(id) has a known endpoint")
        }
    }

    /// Ollama and custom address a server the user runs, which commonly has no
    /// auth — there the base URL is the credential.
    @Test
    func `self-hosted providers require a base URL instead of a key`() {
        for id in [ProviderID.ollama, .custom] {
            let entry = ProviderCatalog.entry(for: id)
            #expect(entry.requiresBaseURL, "\(id) needs a base URL")
            #expect(entry.requiresAPIKey == false, "\(id) commonly has no auth")
        }
    }

    /// This mirrors `ProviderKind.keylessCapable`, which decides whether a
    /// stored row counts as proof of BYO. If the two disagree, the form
    /// collects a credential the entitlement layer will not honour.
    @Test
    func `the keyless providers match the ones the router treats as keyless`() {
        let catalogKeyless = Set(
            ProviderID.allCases
                .filter { !ProviderCatalog.entry(for: $0).requiresAPIKey }
                .compactMap { ProviderKind(rawValue: $0.rawValue) }
        )
        #expect(catalogKeyless == ProviderKind.keylessCapable)
    }

    /// A provider with no adapter in this deployment must not be offered.
    @Test
    func `availability reflects the deployment`() {
        let entries = ProviderCatalog.all { $0 == .openai }
        #expect(entries.first { $0.provider == .openai }?.available == true)
        #expect(entries.first { $0.provider == .anthropic }?.available == false)
    }

    @Test
    func `key hints are shown only where a key is taken`() {
        for entry in ProviderCatalog.all() where entry.keyHint != nil {
            #expect(entry.requiresAPIKey, "\(entry.provider) hints at a key it does not take")
        }
    }
}
