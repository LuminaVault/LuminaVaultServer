@testable import App
import Foundation
import Testing

/// HER-134 — chain behaviour:
/// * transient/network → advance,
/// * permanent → rethrow,
/// * exhausted chain → throw the last seen error.
@Suite("EmbeddingFallbackService")
struct EmbeddingFallbackServiceTests {
    private final class ScriptedService: EmbeddingService, @unchecked Sendable {
        let label: String
        let result: Result<[Float], EmbeddingProviderError>
        nonisolated(unsafe) var callCount = 0

        init(label: String, result: Result<[Float], EmbeddingProviderError>) {
            self.label = label
            self.result = result
        }

        func embed(_: String, tenantID _: UUID) async throws -> [Float] {
            callCount += 1
            switch result {
            case let .success(v): return v
            case let .failure(err): throw err
            }
        }
    }

    @Test
    func `permanent error from primary rethrows immediately — no fallback`() async {
        let primary = ScriptedService(label: "p", result: .failure(.permanent(reason: .authRejected)))
        let fb = ScriptedService(label: "f", result: .success([Float](repeating: 1, count: 1536)))
        let chain = EmbeddingFallbackService(
            primary: primary,
            primaryKind: .openai,
            fallbacks: [(.deterministic, fb)],
        )
        await #expect(throws: EmbeddingProviderError.self) {
            _ = try await chain.embed("hi", tenantID: UUID())
        }
        #expect(primary.callCount == 1)
        #expect(fb.callCount == 0)
    }

    @Test
    func `transient primary advances to fallback`() async throws {
        let primary = ScriptedService(label: "p", result: .failure(.transient(reason: "503")))
        let fb = ScriptedService(label: "f", result: .success([Float](repeating: 0.5, count: 1536)))
        let chain = EmbeddingFallbackService(
            primary: primary,
            primaryKind: .openai,
            fallbacks: [(.deterministic, fb)],
        )
        let v = try await chain.embed("hi", tenantID: UUID())
        #expect(v.count == 1536)
        #expect(primary.callCount == 1)
        #expect(fb.callCount == 1)
    }

    @Test
    func `all-recoverable chain rethrows last error`() async {
        let primary = ScriptedService(label: "p", result: .failure(.transient(reason: "p")))
        let fb = ScriptedService(label: "f", result: .failure(.network(reason: "f")))
        let chain = EmbeddingFallbackService(
            primary: primary,
            primaryKind: .openai,
            fallbacks: [(.deterministic, fb)],
        )
        await #expect(throws: EmbeddingProviderError.self) {
            _ = try await chain.embed("hi", tenantID: UUID())
        }
        #expect(primary.callCount == 1)
        #expect(fb.callCount == 1)
    }
}
