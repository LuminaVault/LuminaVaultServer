@testable import App
import Foundation
import Testing

/// Which upstream failures are evidence about the *user's key*, and which are
/// only evidence that the provider is having a bad minute.
///
/// `/v1/me/providers/{provider}/test` used to call `recordFailure` for every
/// error it saw — rate limits, 500s, timeouts, DNS failures. That stamps
/// `last_failure_code` on the credential row, which the providers pane reads
/// as "this key is broken", so a provider outage told the user to re-enter a
/// perfectly good key.
struct ProviderCredentialEvidenceTests {
    @Test
    func `an auth rejection is evidence about the key`() {
        for status in [401, 403] {
            let error = ProviderError.permanent(provider: .openai, status: status, body: nil)
            #expect(error.isCredentialRejection, "\(status) should mark the credential")
        }
    }

    /// The key authenticated — it is real — but it cannot buy anything, and
    /// that is something the user needs told about the credential itself.
    @Test
    func `credit exhaustion is evidence about the key`() {
        let error = ProviderError.creditExhausted(provider: .openRouter, status: 402, body: nil)
        #expect(error.isCredentialRejection)
    }

    /// The bug, pinned: none of these say anything about the key.
    @Test
    func `provider downtime is not evidence about the key`() {
        let cases: [ProviderError] = [
            .transient(provider: .openai, status: 429, body: nil),
            .transient(provider: .openai, status: 500, body: nil),
            .transient(provider: .openai, status: 503, body: nil),
            .network(provider: .openai, underlying: URLError(.timedOut)),
            .network(provider: .openai, underlying: URLError(.cannotFindHost)),
        ]
        for error in cases {
            #expect(error.isCredentialRejection == false, "\(error) must not stain the credential")
        }
    }

    /// A 400 or 404 usually means our *ping* was wrong — an unknown model
    /// name, say — which is our bug, not the user's key.
    @Test
    func `a malformed request is not evidence about the key`() {
        for status in [400, 404, 422] {
            let error = ProviderError.permanent(provider: .anthropic, status: status, body: nil)
            #expect(error.isCredentialRejection == false, "\(status) is about the request, not the key")
        }
    }
}
