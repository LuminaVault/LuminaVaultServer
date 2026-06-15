@testable import App
import Foundation
import Testing

/// HER-134 — exercises the small enums backing the embedding registry.
/// Kept hermetic (no HTTP / no fluent) so they run on every CI minute.
@Suite("EmbeddingProviderKind + Error", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct EmbeddingKindAndErrorTests {
    @Test
    func `kind init accepts canonical + aliased + case-insensitive inputs`() {
        #expect(EmbeddingProviderKind(rawConfigValue: "openai") == .openai)
        #expect(EmbeddingProviderKind(rawConfigValue: "OpenAI") == .openai)
        #expect(EmbeddingProviderKind(rawConfigValue: "  nomic  ") == .nomic)
        #expect(EmbeddingProviderKind(rawConfigValue: "hermesLocal") == .hermesLocal)
        #expect(EmbeddingProviderKind(rawConfigValue: "hermes_local") == .hermesLocal)
        #expect(EmbeddingProviderKind(rawConfigValue: "hermes-local") == .hermesLocal)
        #expect(EmbeddingProviderKind(rawConfigValue: "local") == .hermesLocal)
        #expect(EmbeddingProviderKind(rawConfigValue: "deterministic") == .deterministic)
        #expect(EmbeddingProviderKind(rawConfigValue: "stub") == .deterministic)
        #expect(EmbeddingProviderKind(rawConfigValue: "not-a-provider") == nil)
        #expect(EmbeddingProviderKind(rawConfigValue: "") == nil)
    }

    @Test
    func `error recoverability matrix`() {
        #expect(EmbeddingProviderError.transient(reason: "x").isRecoverable)
        #expect(EmbeddingProviderError.network(reason: "x").isRecoverable)
        #expect(!EmbeddingProviderError.permanent(reason: .authRejected).isRecoverable)
        #expect(!EmbeddingProviderError.permanent(reason: .endpointMissing).isRecoverable)
        #expect(!EmbeddingProviderError.permanent(reason: .decodeFailed).isRecoverable)
        #expect(!EmbeddingProviderError.capExceeded(tenantID: UUID(), monthlyTokens: 0, cap: 0).isRecoverable)
        #expect(!EmbeddingProviderError.dimMismatch(expected: 1536, got: 768).isRecoverable)
    }
}
