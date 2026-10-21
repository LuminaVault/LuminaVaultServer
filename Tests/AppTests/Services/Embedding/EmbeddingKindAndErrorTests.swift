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
        #expect(EmbeddingProviderKind(rawConfigValue: "openrouter") == .openRouter)
        #expect(EmbeddingProviderKind(rawConfigValue: "OpenRouter") == .openRouter)
        #expect(EmbeddingProviderKind(rawConfigValue: "open_router") == .openRouter)
        #expect(EmbeddingProviderKind(rawConfigValue: "open-router") == .openRouter)
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

    @Test
    func `provider-unavailable matrix: outages, keys and credit stop the heal pass; bad inputs do not`() {
        #expect(EmbeddingProviderError.transient(reason: "x").isProviderUnavailable)
        #expect(EmbeddingProviderError.network(reason: "x").isProviderUnavailable)
        #expect(EmbeddingProviderError.permanent(reason: .paymentRequired).isProviderUnavailable)
        #expect(EmbeddingProviderError.permanent(reason: .authRejected).isProviderUnavailable)
        #expect(EmbeddingProviderError.permanent(reason: .missingAPIKey).isProviderUnavailable)
        #expect(!EmbeddingProviderError.permanent(reason: .requestRejected).isProviderUnavailable)
        #expect(!EmbeddingProviderError.permanent(reason: .decodeFailed).isProviderUnavailable)
        #expect(!EmbeddingProviderError.capExceeded(tenantID: UUID(), monthlyTokens: 0, cap: 0).isProviderUnavailable)
        #expect(!EmbeddingProviderError.dimMismatch(expected: 1536, got: 768).isProviderUnavailable)
    }

    @Test
    func `provider error message is read from every common body shape`() {
        typealias Response = EmbeddingProviderError.ProviderResponse
        #expect(Response(status: 402, body: Data(#"{"error":{"message":"Insufficient credits"}}"#.utf8)).message == "Insufficient credits")
        #expect(Response(status: 400, body: Data(#"{"error":"bad input"}"#.utf8)).message == "bad input")
        #expect(Response(status: 400, body: Data(#"{"message":"top level"}"#.utf8)).message == "top level")
        #expect(Response(status: 502, body: Data("  Bad\n gateway  ".utf8)).message == "Bad gateway")
        #expect(Response(status: 500, body: Data()).message == nil)
        #expect(Response(status: 500, body: Data(#"{"detail":"x"}"#.utf8)).message == nil)
        #expect(Response(status: 401, body: Data("Bearer abc.def rejected".utf8)).message == "[redacted] [redacted] rejected")
    }

    private struct FailingEmbedding: EmbeddingService {
        let error: any Error
        func embed(_: String, tenantID _: UUID) async throws -> [Float] {
            throw error
        }
    }

    @Test
    func `write and query embeds degrade to nil on a provider failure`() async throws {
        let down = FailingEmbedding(error: EmbeddingProviderError.permanent(reason: .paymentRequired))
        #expect(try await down.embedForWrite("note", tenantID: UUID(), operation: "test") == nil)
        #expect(try await down.embedForQuery("query", tenantID: UUID(), operation: "test") == nil)
        let batch = try await down.embedBatchForWrite(["a", "b", "c"], tenantID: UUID(), operation: "test")
        #expect(batch.count == 3)
        #expect(batch.allSatisfy { $0 == nil })

        let working = DeterministicEmbeddingService()
        #expect(try await working.embedForWrite("note", tenantID: UUID(), operation: "test")?.count == 1536)
    }

    @Test
    func `a cancelled embed is rethrown, not saved as degraded`() async {
        let cancelled = FailingEmbedding(error: CancellationError())
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.embedForWrite("note", tenantID: UUID(), operation: "test")
        }
    }
}
