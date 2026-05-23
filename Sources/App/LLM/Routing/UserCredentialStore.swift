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
        let credential: ResolvedCredential?
        let expiresAt: Date
    }

    private let fluent: Fluent
    private let secretBox: SecretBox
    private let logger: Logger
    private let ttl: TimeInterval

    private var cache: [CacheKey: CacheEntry] = [:]

    init(fluent: Fluent, secretBox: SecretBox, logger: Logger, ttl: TimeInterval = 600) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.logger = logger
        self.ttl = ttl
    }

    /// Look up a credential. Returns `nil` (cached) when no row exists.
    /// Never throws on a missing row — adapters fall back to the
    /// deployment-wide env API key in that case.
    func credential(for provider: ProviderKind, tenantID: UUID) async throws -> ResolvedCredential? {
        let key = CacheKey(tenantID: tenantID, provider: provider.rawValue)
        if let cached = cache[key], cached.expiresAt > Date() {
            return cached.credential
        }
        let row = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .first()
        let resolved = try row.map { try decode($0, tenantID: tenantID) }
        cache[key] = CacheEntry(credential: resolved, expiresAt: Date().addingTimeInterval(ttl))
        return resolved
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
        label: String?,
    ) async throws {
        let existing = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == provider.rawValue)
            .first()
        let row = existing ?? UserProviderCredential()
        row.tenantID = tenantID
        row.provider = provider.rawValue
        row.credentialKind = credentialKind
        if let apiKey, !apiKey.isEmpty {
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
