import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

// MARK: - Server-side conformances

extension VaultStatusResponse: @retroactive ResponseEncodable {}

/// HER-35 — owns the "first run" bootstrap that flips `User.vault_initialized`
/// from `false` to `true`. Replaces the previous side-effect inside
/// `DefaultAuthService.register`, which implicitly created `SOUL.md` before
/// the client had ever asked.
///
/// On success the tenant has:
///   - `<vaultRoot>/tenants/<id>/{raw,wiki,memories}/` on disk
///   - `SOUL.md` rendered from the default template (vault + Hermes mirror)
///   - The five product-default Spaces seeded (`SpaceDefaults.entries`)
///   - `users.vault_initialized = true`
///
/// Idempotent: a second call returns the current status without re-seeding.
struct VaultInitService {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let soulService: SOULService
    let spacesService: SpacesService
    let vectorIndexService: TenantVectorIndexService?
    let logger: Logger

    init(
        fluent: Fluent,
        vaultPaths: VaultPathService,
        soulService: SOULService,
        spacesService: SpacesService,
        vectorIndexService: TenantVectorIndexService? = nil,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.vaultPaths = vaultPaths
        self.soulService = soulService
        self.spacesService = spacesService
        self.vectorIndexService = vectorIndexService
        self.logger = logger
    }

    /// Idempotent. Returns the response the caller should ship to the client.
    func create(for user: User) async throws -> VaultStatusResponse {
        let tenantID = try user.requireID()
        if user.vaultInitialized {
            return try await status(for: user)
        }

        try vaultPaths.ensureTenantDirectories(for: tenantID)
        do {
            try soulService.initIfMissing(for: user)
        } catch {
            logger.error("vault.init soul-failed tenant=\(tenantID): \(error)")
            throw HTTPError(.serviceUnavailable, message: "could not initialize SOUL.md")
        }

        let seededSlugs = try await spacesService.seedDefaults(tenantID: tenantID)
        user.vaultInitialized = true
        try await user.save(on: fluent.db())

        // HER-234 — best-effort per-tenant HNSW index. The global
        // HNSW from M39 still serves searches if this fails, so we
        // log and continue rather than rolling back vault-init.
        if let vectorIndexService {
            do {
                try await vectorIndexService.ensureIndex(for: tenantID)
            } catch {
                logger.error("vault.init.hnsw-index-failed tenant=\(tenantID): \(error)")
            }
        }

        logger.info("vault.created tenant=\(tenantID) seeded=\(seededSlugs.count)")
        return VaultStatusResponse(
            initialized: true,
            createdAt: user.updatedAt,
            defaultSpaceSlugs: SpaceDefaults.entries.map(\.slug),
        )
    }

    func status(for user: User) async throws -> VaultStatusResponse {
        VaultStatusResponse(
            initialized: user.vaultInitialized,
            createdAt: user.vaultInitialized ? user.updatedAt : nil,
            defaultSpaceSlugs: user.vaultInitialized ? SpaceDefaults.entries.map(\.slug) : [],
        )
    }
}
