@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// HER-43 Slice 4 — BYO embedding-key memory plugin. Pure-logic (no DB / no
/// HTTP), avoiding the AsyncKit teardown SIGILL (HER-310).
@Suite("Memory provider plugin (BYO embeddings)")
struct MemoryProviderPluginTests {
    @Test
    func `byok-embeddings is a memory plugin with a required secret key`() {
        let entry = PluginCatalog.entry(slug: "byok-embeddings")
        #expect(entry != nil)
        #expect(entry?.dto.category == .memory)
        #expect(entry?.dto.capabilityKind == .memory)
        #expect(entry?.dto.configFields.contains { $0.key == "access_token" && $0.kind == .secret && $0.isRequired } == true)
        #expect(PluginCatalog.validate(slug: "byok-embeddings", config: [:]) == .missing("access_token"))
        #expect(PluginCatalog.validate(slug: "byok-embeddings", config: ["access_token": "sk-x"]) == .ok)
    }

    @Test
    func `memory entry surfaces under .memory and does not change connector slugs`() {
        #expect(PluginCatalog.catalog(category: .memory).map(\.slug) == ["byok-embeddings"])
        // Regression: connector catalog unchanged by the new memory entry.
        #expect(PluginCatalog.catalog(category: .connector).map(\.slug) == ["raindrop", "readwise", "rss"])
    }
}

/// Stub resolver + a tagged embedding service to prove delegation.
private struct TaggedEmbedding: EmbeddingService {
    let tag: Float
    func embed(_: String, tenantID _: UUID) async throws -> [Float] {
        [tag]
    }
}

private struct StubResolver: PerTenantEmbeddingResolving {
    let perTenant: (any EmbeddingService)?
    func service(for _: UUID) async -> (any EmbeddingService)? {
        perTenant
    }
}

@Suite("Tenant-aware embedding routing")
struct TenantAwareEmbeddingServiceTests {
    @Test
    func `uses per-tenant service when resolver returns one`() async throws {
        let svc = TenantAwareEmbeddingService(
            global: TaggedEmbedding(tag: 0),
            resolver: StubResolver(perTenant: TaggedEmbedding(tag: 1))
        )
        #expect(try await svc.embed("x", tenantID: UUID()) == [1])
    }

    @Test
    func `falls through to global when resolver returns nil`() async throws {
        let svc = TenantAwareEmbeddingService(
            global: TaggedEmbedding(tag: 0),
            resolver: StubResolver(perTenant: nil)
        )
        #expect(try await svc.embed("x", tenantID: UUID()) == [0])
    }
}
