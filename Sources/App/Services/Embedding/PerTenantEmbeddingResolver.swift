import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Resolves the per-tenant embedding service (if any) for a tenant. Abstracted
/// so `TenantAwareEmbeddingService` can be unit-tested with a stub.
protocol PerTenantEmbeddingResolving: Sendable {
    func service(for tenantID: UUID) async -> (any EmbeddingService)?
}

/// HER-43 (Slice 4) — resolves a per-tenant embedding service from the tenant's
/// installed "byok-embeddings" memory plugin. Reads the enabled `PluginInstall`
/// row, decrypts the API key (SecretBox), and builds a keyed embedding service
/// of the *active provider kind* via `makeKeyedService`. Results (including
/// "no per-tenant service") are cached with a short TTL so the embedding hot
/// path doesn't hit the DB on every call; key/install changes propagate within
/// the TTL window.
actor PerTenantEmbeddingResolver: PerTenantEmbeddingResolving {
    static let byokEmbeddingsSlug = "byok-embeddings"
    static let configKey = "access_token"

    private struct Cached {
        let service: (any EmbeddingService)?
        let at: Date
    }

    private let fluent: Fluent
    private let secretBox: SecretBox
    /// Builds a keyed embedding service of the active kind, or nil if the
    /// active kind isn't BYO-keyable (deterministic / hermesLocal).
    private let makeKeyedService: @Sendable (_ apiKey: String) -> (any EmbeddingService)?
    private let ttl: TimeInterval
    private let logger: Logger
    private var cache: [UUID: Cached] = [:]

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        ttl: TimeInterval = 300,
        logger: Logger,
        makeKeyedService: @escaping @Sendable (_ apiKey: String) -> (any EmbeddingService)?,
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.ttl = ttl
        self.logger = logger
        self.makeKeyedService = makeKeyedService
    }

    func service(for tenantID: UUID) async -> (any EmbeddingService)? {
        if let cached = cache[tenantID], Date().timeIntervalSince(cached.at) < ttl {
            return cached.service
        }
        let built = await build(tenantID: tenantID)
        cache[tenantID] = Cached(service: built, at: Date())
        return built
    }

    private func build(tenantID: UUID) async -> (any EmbeddingService)? {
        guard let row = try? await PluginInstall.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$pluginSlug == Self.byokEmbeddingsSlug)
            .filter(\.$status == PluginInstallState.enabled)
            .first()
        else { return nil }

        let sealed = SecretBox.Sealed(ciphertext: row.configCiphertext, nonce: row.configNonce)
        guard let plaintext = try? secretBox.open(sealed, tenantID: tenantID),
              let config = try? JSONDecoder().decode([String: String].self, from: Data(plaintext.utf8)),
              let key = config[Self.configKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            logger.warning("byok-embeddings install present but config unreadable tenant=\(tenantID)")
            return nil
        }
        return makeKeyedService(key)
    }
}
