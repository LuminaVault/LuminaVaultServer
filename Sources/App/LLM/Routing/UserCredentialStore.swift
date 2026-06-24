import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-252 — actor that owns per-tenant external-LLM credentials. Reads
/// rows from `user_provider_credentials`, decrypts via `SecretBox`, and
/// hands back a `ResolvedCredential` to adapters at request time.
///
/// Cache: 10-minute TTL per `(tenantID, provider)` so the chat hot path
/// avoids a DB hit on every token. Invalidation is best-effort on
/// upsert/delete; stale reads are bounded by TTL anyway.
actor UserCredentialStore {
    /// Resolved credential surface used by adapters. `apiKey` carries
    /// the decrypted plaintext (API key or OAuth refresh token), `baseURL`
    /// the optional per-user endpoint override (e.g. Ollama host URL).
    /// At least one is non-nil for a usable row.
    struct ResolvedCredential {
        let apiKey: String?
        let baseURL: URL?
        let label: String?
    }

    /// Cache key. `provider` is the `ProviderKind.rawValue` string to
    /// avoid needing `Hashable` on the enum cases at this layer.
    private struct CacheKey: Hashable {
        let tenantID: UUID
        let provider: String
    }

    private struct CacheEntry {
        /// Ordered candidate keys (primary first, then pool). Round-robin
        /// rotates across these; empty = no usable credential.
        let candidates: [ResolvedCredential]
        let expiresAt: Date
    }

    private let fluent: Fluent
    private let secretBox: SecretBox
    private let logger: Logger
    private let ttl: TimeInterval

    /// Resolver for xAI OAuth-linked tenant containers. When the per-user
    /// credential row for .xai uses kind "oauth" (SuperGrok / linked account
    /// from the integrations/xai flow), we return the container's apiServerKey
    /// + internal base URL instead of a user apiKey. This lets the normal
    /// OpenAICompatibleAdapter hit the tenant Hermes gateway (which holds the
    /// linked xAI session) for grok-* models.
    private let xaiContainerResolver: (@Sendable (UUID) async -> HermesContainerHandle?)?

    private var cache: [CacheKey: CacheEntry] = [:]
    /// Per-(tenant,provider) round-robin cursor. Not persisted — rotation is
    /// best-effort and resets on restart, which is fine for load-spreading.
    private var rotation: [CacheKey: Int] = [:]

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        logger: Logger,
        ttl: TimeInterval = 600,
        xaiContainerResolver: (@Sendable (UUID) async -> HermesContainerHandle?)? = nil
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.logger = logger
        self.ttl = ttl
        self.xaiContainerResolver = xaiContainerResolver
    }

    /// Look up a credential. Returns `nil` (cached) when no row exists.
    /// Never throws on a missing row — adapters fall back to the
    /// deployment-wide env API key in that case. When a round-robin pool is
    /// configured, rotates across [primary + pool keys] per call to spread
    /// rate limits; the candidate list is cached (TTL) while the rotation
    /// cursor advances live.
    func credential(for provider: ProviderKind, tenantID: UUID) async throws -> ResolvedCredential? {
        let key = CacheKey(tenantID: tenantID, provider: provider.rawValue)
        let candidates: [ResolvedCredential]
        if let cached = cache[key], cached.expiresAt > Date() {
            candidates = cached.candidates
        } else {
            candidates = try await loadCandidates(provider: provider, tenantID: tenantID)
            cache[key] = CacheEntry(candidates: candidates, expiresAt: Date().addingTimeInterval(ttl))
        }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }
        let idx = (rotation[key] ?? 0) % candidates.count
        rotation[key] = idx + 1
        return candidates[idx]
    }

    /// Builds the ordered candidate list: the primary credential (if usable)
    /// followed by pool keys. Pool keys inherit the primary's `baseURL` so a
    /// custom endpoint still applies to every rotated key.
    ///
    /// Special case for ProviderKind.xai + credentialKind "oauth": if the
    /// tenant has completed the xAI SuperGrok connect (container has
    /// xaiConnectedAt), we return the container's apiServerKey + base URL.
    /// This routes grok-* calls through the Hermes container (which holds the
    /// linked session) using the normal OpenAI-compatible path. No per-user
    /// apiKey is stored for the oauth marker row.
    private func loadCandidates(provider: ProviderKind, tenantID: UUID) async throws -> [ResolvedCredential] {
        let primaryRow = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .first()

        // xAI oauth (SuperGrok linked) marker path — return container creds
        // so the adapter talks to the per-tenant Hermes gateway instead of
        // raw api.x.ai. The container internally forwards using the connected
        // xAI session.
        if provider == .xai,
           let row = primaryRow,
           row.credentialKind == "oauth",
           let resolver = xaiContainerResolver,
           let handle = await resolver(tenantID),
           handle.xaiConnectedAt != nil {
            let base = URL(string: handle.baseURL)
            return [ResolvedCredential(apiKey: handle.apiServerKey, baseURL: base, label: row.label)]
        }

        var candidates: [ResolvedCredential] = []
        let primaryBaseURL = primaryRow?.baseURL.flatMap { URL(string: $0) }
        if let primaryRow {
            let resolved = try decode(primaryRow, tenantID: tenantID)
            if resolved.apiKey != nil || resolved.baseURL != nil {
                candidates.append(resolved)
            }
        }
        let poolRows = try await UserProviderCredentialPoolKey.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .sort(\.$createdAt)
            .all()
        for row in poolRows {
            guard let ct = row.ciphertext, let nonce = row.nonce else { continue }
            let apiKey = try secretBox.open(.init(ciphertext: ct, nonce: nonce), tenantID: tenantID)
            candidates.append(ResolvedCredential(apiKey: apiKey, baseURL: primaryBaseURL, label: row.label))
        }
        return candidates
    }

    /// Upsert a credential. Encrypts `apiKey` if provided. `baseURL` is
    /// stored plaintext (it's not a secret). Resets `verified_at` and
    /// `last_failure_*` so the iOS pane re-surfaces the unverified
    /// state — caller is expected to immediately re-run /test.
    func upsert(
        tenantID: UUID,
        provider: ProviderKind,
        credentialKind: String,
        apiKey: String?,
        baseURL: String?,
        label: String?
    ) async throws {
        let existing = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .first()
        let row = existing ?? UserProviderCredential()
        row.tenantID = tenantID
        row.provider = provider.rawValue
        row.credentialKind = credentialKind
        if credentialKind == "oauth" {
            // oauth marker (SuperGrok link) never carries a secret.
            row.ciphertext = nil
            row.nonce = nil
        } else if let apiKey, !apiKey.isEmpty {
            let sealed = try secretBox.seal(apiKey, tenantID: tenantID)
            row.ciphertext = sealed.ciphertext
            row.nonce = sealed.nonce
        } else if apiKey?.isEmpty == true {
            // Empty string explicitly clears the secret; preserves a
            // baseURL-only row (e.g. Ollama).
            row.ciphertext = nil
            row.nonce = nil
        }
        row.baseURL = baseURL
        row.label = label
        row.verifiedAt = nil
        row.lastFailureAt = nil
        row.lastFailureCode = nil
        try await row.save(on: fluent.db())
        invalidate(tenantID: tenantID, provider: provider)
    }

    /// Hard delete the row. Used by `DELETE /v1/me/providers/{provider}`.
    func delete(tenantID: UUID, provider: ProviderKind) async throws {
        try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .delete()
        invalidate(tenantID: tenantID, provider: provider)
    }

    /// Stamp `verified_at` + clear failure fields. Called by the /test
    /// endpoint on a successful probe.
    func recordSuccess(tenantID: UUID, provider: ProviderKind) async throws {
        guard let row = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .first()
        else { return }
        row.verifiedAt = Date()
        row.lastFailureAt = nil
        row.lastFailureCode = nil
        try await row.save(on: fluent.db())
        invalidate(tenantID: tenantID, provider: provider)
    }

    /// Stamp `last_failure_at` + `last_failure_code`. Called by both the
    /// /test endpoint and the runtime adapter path so iOS can surface a
    /// stable badge on the providers pane.
    func recordFailure(tenantID: UUID, provider: ProviderKind, code: String) async throws {
        guard let row = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .first()
        else { return }
        row.lastFailureAt = Date()
        row.lastFailureCode = code
        try await row.save(on: fluent.db())
        invalidate(tenantID: tenantID, provider: provider)
    }

    /// Drop a single cache entry. Public so PUT/DELETE handlers can
    /// proactively bust the cache without waiting for TTL.
    func invalidate(tenantID: UUID, provider: ProviderKind) {
        cache[CacheKey(tenantID: tenantID, provider: provider.rawValue)] = nil
    }

    // MARK: - Credential pool (round-robin)

    /// Adds an API key to the provider's round-robin pool. Returns the saved
    /// row so the controller can echo its id/label/createdAt (never the key).
    func addPoolKey(
        tenantID: UUID,
        provider: ProviderKind,
        apiKey: String,
        label: String?
    ) async throws -> UserProviderCredentialPoolKey {
        let row = UserProviderCredentialPoolKey()
        row.tenantID = tenantID
        row.provider = provider.rawValue
        let sealed = try secretBox.seal(apiKey, tenantID: tenantID)
        row.ciphertext = sealed.ciphertext
        row.nonce = sealed.nonce
        row.label = label
        try await row.save(on: fluent.db())
        invalidate(tenantID: tenantID, provider: provider)
        return row
    }

    /// Lists pool keys (rows; the controller maps to a key-free DTO).
    func listPoolKeys(tenantID: UUID, provider: ProviderKind) async throws -> [UserProviderCredentialPoolKey] {
        try await UserProviderCredentialPoolKey.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .sort(\.$createdAt)
            .all()
    }

    /// Removes one pool key by id (scoped to the tenant + provider).
    func deletePoolKey(tenantID: UUID, provider: ProviderKind, id: UUID) async throws {
        try await UserProviderCredentialPoolKey.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .filter(\.$id == id)
            .delete()
        invalidate(tenantID: tenantID, provider: provider)
    }

    // MARK: - Internals

    private func decode(_ row: UserProviderCredential, tenantID: UUID) throws -> ResolvedCredential {
        let key: String? = if let ct = row.ciphertext, let nonce = row.nonce {
            try secretBox.open(.init(ciphertext: ct, nonce: nonce), tenantID: tenantID)
        } else {
            nil
        }
        let url: URL? = row.baseURL.flatMap { URL(string: $0) }
        return ResolvedCredential(apiKey: key, baseURL: url, label: row.label)
    }
}
