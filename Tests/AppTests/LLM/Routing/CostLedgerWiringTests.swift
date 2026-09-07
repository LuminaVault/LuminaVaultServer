@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// The USD meter that had a table (M73), a complete service, and no caller.
///
/// `usage_meter` counts tokens, which cannot be compared across providers
/// whose per-million rates differ by two orders of magnitude — 800_000
/// micro-USD for Claude Haiku input against 150_000 for GPT-4o mini. Until
/// `cost_ledger` was written to, "what does this tenant cost" had no answer.
struct CostLedgerWiringTests {
    @Test
    func `cost comes from the catalog rate for the model actually used`() {
        // Claude 3.5 Haiku: 800_000 in / 4_000_000 out per million tokens.
        let usd = RoutedLLMTransport.catalogCost(
            provider: .anthropic,
            model: "claude-3-5-haiku-20241022",
            tokensIn: 1_000_000,
            tokensOut: 1_000_000,
            cerberus: nil
        )
        #expect(usd == 4_800_000)
    }

    /// The same token count against a cheaper model must not cost the same —
    /// this is the whole reason a token meter cannot answer the cost question.
    @Test
    func `two providers at identical token counts do not cost the same`() {
        let anthropic = RoutedLLMTransport.catalogCost(
            provider: .anthropic,
            model: "claude-3-5-haiku-20241022",
            tokensIn: 100_000,
            tokensOut: 0,
            cerberus: nil
        )
        let openai = RoutedLLMTransport.catalogCost(
            provider: .openai,
            model: "gpt-4o-mini",
            tokensIn: 100_000,
            tokensOut: 0,
            cerberus: nil
        )
        #expect(anthropic == 80000)
        #expect(openai == 15000)
        #expect(anthropic > openai)
    }

    /// Recording a guessed price would be worse than recording nothing: the
    /// ledger's only job is to answer the cost question truthfully.
    @Test
    func `a model with no known rate records nothing`() {
        #expect(RoutedLLMTransport.catalogCost(
            provider: .openai,
            model: "some-model-we-have-never-priced",
            tokensIn: 1_000_000,
            tokensOut: 1_000_000,
            cerberus: nil
        ) == 0)
    }

    @Test
    func `zero and negative token counts cost nothing`() {
        #expect(RoutedLLMTransport.catalogCost(
            provider: .anthropic, model: "claude-3-5-haiku-20241022",
            tokensIn: 0, tokensOut: 0, cerberus: nil
        ) == 0)
        #expect(RoutedLLMTransport.catalogCost(
            provider: .anthropic, model: "claude-3-5-haiku-20241022",
            tokensIn: -5, tokensOut: -5, cerberus: nil
        ) == 0)
    }

    // MARK: - What actually gets written

    /// A BYOK call is billed to the tenant by the provider directly. Metering
    /// it would invent a cost we never incur and make the ledger answer in the
    /// expensive direction — so the mode is checked before any rate lookup.
    @Test
    func `BYOK traffic is never charged to the ledger`() {
        #expect(RoutedLLMTransport.ledgerCharge(
            credentialMode: .byok,
            provider: .anthropic,
            model: "claude-3-5-haiku-20241022",
            tokensIn: 1_000_000,
            tokensOut: 1_000_000,
            cerberus: nil
        ) == nil)
    }

    /// The same call on the platform's key is exactly what the ledger is for.
    @Test
    func `managed traffic is charged at the catalog rate`() {
        let charge = RoutedLLMTransport.ledgerCharge(
            credentialMode: .managed,
            provider: .anthropic,
            model: "claude-3-5-haiku-20241022",
            tokensIn: 1_000_000,
            tokensOut: 1_000_000,
            cerberus: nil
        )
        #expect(charge?.provider == .anthropic)
        #expect(charge?.usdMicros == 4_800_000)
    }

    /// The legacy router leaves `credentialMode` nil on every chat call. Nil
    /// is not BYOK — those calls run on the platform key and must be metered,
    /// or the ledger silently undercounts the traffic that costs the most.
    @Test
    func `an unknown credential mode is treated as managed`() {
        #expect(RoutedLLMTransport.ledgerCharge(
            credentialMode: nil,
            provider: .openai,
            model: "gpt-4o-mini",
            tokensIn: 1_000_000,
            tokensOut: 0,
            cerberus: nil
        )?.usdMicros == 150_000)
    }

    @Test
    func `an unpriced model writes no row even in managed mode`() {
        #expect(RoutedLLMTransport.ledgerCharge(
            credentialMode: .managed,
            provider: .openai,
            model: "some-model-we-have-never-priced",
            tokensIn: 1_000_000,
            tokensOut: 1_000_000,
            cerberus: nil
        ) == nil)
    }
}
