import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-252 — read/write surface for `user_llm_preferences` with an
/// in-process TTL cache. Read on every chat call (the hot path), so the
/// cache matters; writes are rare (settings PUT) so invalidation is
/// best-effort.
actor UserLLMPreferenceRepository {
    /// Wire-friendly snapshot returned to callers. Keeping it as a
    /// value type (not the Fluent model) avoids leaking the row's
    /// mutability beyond the actor.
    struct Snapshot: Equatable {
        let mode: UserLLMPreference.Mode
        let primaryProvider: ProviderKind
        let primaryModel: String
        let fallbackChain: [Step]
        /// Empty = all providers allowed.
        let allowedProviders: [ProviderKind]
        let blockedProviders: [ProviderKind]

        struct Step: Equatable {
            let provider: ProviderKind
            let model: String
        }
    }

    private struct CacheEntry {
        let snapshot: Snapshot?
        let expiresAt: Date
    }

    private let fluent: Fluent
    private let logger: Logger
    private let ttl: TimeInterval
    private var cache: [UUID: CacheEntry] = [:]

    init(fluent: Fluent, logger: Logger, ttl: TimeInterval = 600) {
        self.fluent = fluent
        self.logger = logger
        self.ttl = ttl
    }

    /// Returns the user's preference, or `nil` if no row exists. Callers
    /// fall through to the static `TableModelRouter` on `nil`.
    func get(tenantID: UUID) async throws -> Snapshot? {
        if let cached = cache[tenantID], cached.expiresAt > Date() {
            return cached.snapshot
        }
        let row = try await UserLLMPreference.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
        let snapshot = row.map { Self.decode($0) }
        cache[tenantID] = CacheEntry(snapshot: snapshot, expiresAt: Date().addingTimeInterval(ttl))
        return snapshot
    }

    /// Upsert (PUT semantics — replaces the entire row). Validation that
    /// providers are non-empty + parseable is the controller's job; this
    /// actor stores whatever it's given.
    func upsert(
        tenantID: UUID,
        mode: UserLLMPreference.Mode,
        primaryProvider: ProviderKind,
        primaryModel: String,
        fallbackChain: [Snapshot.Step],
        allowedProviders: [ProviderKind],
        blockedProviders: [ProviderKind],
    ) async throws -> Snapshot {
        let existing = try await UserLLMPreference.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
        let row = existing ?? UserLLMPreference()
        row.tenantID = tenantID
        row.mode = mode.rawValue
        row.primaryProvider = primaryProvider.rawValue
        row.primaryModel = primaryModel
        row.fallbackChain = UserLLMPreference.FallbackChain(steps: fallbackChain.map {
            UserLLMPreference.FallbackStep(provider: $0.provider.rawValue, model: $0.model)
        })
        row.allowedProviders = UserLLMPreference.ProviderList(providers: allowedProviders.map(\.rawValue))
        row.blockedProviders = UserLLMPreference.ProviderList(providers: blockedProviders.map(\.rawValue))
        try await row.save(on: fluent.db())
        let snapshot = Self.decode(row)
        cache[tenantID] = CacheEntry(snapshot: snapshot, expiresAt: Date().addingTimeInterval(ttl))
        return snapshot
    }

    func invalidate(tenantID: UUID) {
        cache[tenantID] = nil
    }

    private static func decode(_ row: UserLLMPreference) -> Snapshot {
        Snapshot(
            // HER-300 — fall back to .managed if a row somehow has a value
            // outside the enum; managed is the "least surprising" default
            // since it always routes through the shared gateway.
            mode: UserLLMPreference.Mode(rawValue: row.mode) ?? .managed,
            primaryProvider: ProviderKind(rawValue: row.primaryProvider) ?? .hermesGateway,
            primaryModel: row.primaryModel,
            fallbackChain: row.fallbackChain.steps.compactMap { step in
                guard let provider = ProviderKind(rawValue: step.provider) else { return nil }
                return Snapshot.Step(provider: provider, model: step.model)
            },
            allowedProviders: (row.allowedProviders?.providers ?? []).compactMap { ProviderKind(rawValue: $0) },
            blockedProviders: (row.blockedProviders?.providers ?? []).compactMap { ProviderKind(rawValue: $0) },
        )
    }
}
