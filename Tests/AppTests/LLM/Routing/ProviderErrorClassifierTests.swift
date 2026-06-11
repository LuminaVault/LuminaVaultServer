@testable import App
import Foundation
import Testing

/// HER-252 — golden-table coverage of `ProviderErrorClassifier`. The
/// classifier is on the chat hot path; misclassifying a 403 with a
/// `insufficient_quota` body as `.permanent` would break failover, so
/// every code branch + every credit marker gets a pinned test.
struct ProviderErrorClassifierTests {
    private static func classify(_ status: Int, body: String? = nil) -> ProviderError {
        ProviderErrorClassifier.classify(
            provider: .openai,
            status: status,
            body: body.flatMap { Data($0.utf8) }
        )
    }

    @Test
    func `401 maps to permanent`() {
        let error = Self.classify(401)
        if case .permanent = error { /* ok */ } else {
            Issue.record("expected .permanent, got \(error)")
        }
        #expect(!error.isRecoverable)
        #expect(error.reasonCode == "upstream_rejected")
    }

    @Test
    func `402 maps to creditExhausted`() {
        let error = Self.classify(402)
        if case .creditExhausted = error { /* ok */ } else {
            Issue.record("expected .creditExhausted, got \(error)")
        }
        #expect(error.isRecoverable, "402 must fall over to the next candidate")
        #expect(error.reasonCode == "credit_exhausted")
    }

    @Test
    func `403 plain maps to permanent`() {
        let error = Self.classify(403, body: "{\"error\":\"forbidden\"}")
        if case .permanent = error { /* ok */ } else {
            Issue.record("expected .permanent, got \(error)")
        }
    }

    @Test(arguments: [
        "{\"error\":{\"type\":\"insufficient_quota\"}}",
        "Quota exceeded for organization xyz",
        "Out of credits — top up your balance",
        "Your billing subscription has lapsed",
        "Payment required to continue",
        "insufficient_balance",
    ])
    func `403 with credit marker maps to creditExhausted`(body: String) {
        let error = Self.classify(403, body: body)
        if case .creditExhausted = error { /* ok */ } else {
            Issue.record("expected .creditExhausted for body \(body), got \(error)")
        }
        #expect(error.isRecoverable)
        #expect(error.reasonCode == "credit_exhausted")
    }

    @Test(arguments: [408, 425, 429])
    func `transient retry codes`(status: Int) {
        let error = Self.classify(status)
        if case .transient = error { /* ok */ } else {
            Issue.record("expected .transient for status \(status), got \(error)")
        }
        #expect(error.isRecoverable)
    }

    @Test(arguments: [500, 502, 503, 504, 599])
    func `5xx maps to transient`(status: Int) {
        let error = Self.classify(status)
        if case .transient = error { /* ok */ } else {
            Issue.record("expected .transient for \(status), got \(error)")
        }
        #expect(error.isRecoverable)
    }

    @Test
    func `429 reasonCode is rate_limit not upstream_error`() {
        let error = Self.classify(429)
        #expect(error.reasonCode == "rate_limit")
    }

    @Test
    func `5xx reasonCode is upstream_error`() {
        let error = Self.classify(503)
        #expect(error.reasonCode == "upstream_error")
    }

    @Test
    func `404 maps to permanent`() {
        let error = Self.classify(404)
        if case .permanent = error { /* ok */ } else {
            Issue.record("expected .permanent, got \(error)")
        }
    }

    @Test
    func `unknown 4xx maps to permanent`() {
        let error = Self.classify(418)
        if case .permanent = error { /* ok */ } else {
            Issue.record("expected .permanent, got \(error)")
        }
    }

    @Test
    func `nil body never matches credit marker`() {
        // 403 + no body → should NOT be classified as credit exhaustion.
        let error = Self.classify(403, body: nil)
        if case .creditExhausted = error {
            Issue.record("403 with nil body must not be misclassified as credit exhaustion")
        }
    }
}

/// HER-252 — `ProviderError.userMessage` / `.reasonCode` are surfaced
/// verbatim on SSE `.fallback` events and `provider_failover_events`
/// rows. Pin the strings.
struct ProviderErrorSurfaceTests {
    @Test
    func `creditExhausted carries provider name`() {
        let error = ProviderError.creditExhausted(provider: .xai, status: 403, body: nil)
        #expect(error.userMessage.contains("Grok"))
        #expect(error.userMessage.lowercased().contains("credit"))
    }

    @Test
    func `network error mentions provider`() {
        let error = ProviderError.network(provider: .anthropic, underlying: NSError(domain: "", code: 0))
        #expect(error.userMessage.contains("Anthropic"))
    }
}
