import Foundation

/// HER-43 (Slice 4) — wraps the global embedding service so a tenant who has
/// installed the "your own embeddings key" memory plugin (BYO key) gets routed
/// through a service built with *their* key. Critically it uses the SAME
/// provider-kind + model as the global default, so the vector space is
/// identical — existing memories stay searchable, no re-embedding.
///
/// Tenants without the plugin (or when no per-tenant service can be built)
/// fall through to the global service unchanged.
struct TenantAwareEmbeddingService: EmbeddingService {
    let global: any EmbeddingService
    let resolver: any PerTenantEmbeddingResolving

    func embed(_ text: String, tenantID: UUID) async throws -> [Float] {
        if let perTenant = await resolver.service(for: tenantID) {
            return try await perTenant.embed(text, tenantID: tenantID)
        }
        return try await global.embed(text, tenantID: tenantID)
    }
}
