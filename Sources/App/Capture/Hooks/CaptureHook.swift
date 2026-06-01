import Foundation

// HER-54 (Slice 1) — capture-hook engine. The "Obsidian-style" extension
// point for the capture pipeline: an installed `.captureHook` plugin can
// transform a captured item at a declared stage before it is persisted.
//
// Mirrors the existing `URLEnricher` chain and `PluginConnector` registry
// pattern — a hook is a small, `Sendable` unit that takes a context and
// returns a (possibly) transformed context. No third-party code runs in
// this slice; hooks are first-party and resolved by `binding` exactly like
// connectors (see `PluginConnector` / `ConnectorRegistry`).

/// Where in the capture pipeline a hook runs. Stringly-typed (like
/// `SkillEventType`) so the taxonomy is stable across slices.
enum CaptureHookPoint: String, CaseIterable {
    /// After URL enrichment produced final `EnrichedMetadata`, before the
    /// vault markdown is rendered/written. The only point wired in Slice 1.
    case postEnrich = "post_enrich"
    /// RESERVED (not yet dispatched) — before the initial vault file write in
    /// `LinkCaptureService`, for later text/photo capture slices.
    case beforePersist = "before_persist"
}

/// The mutable payload a hook transforms. `EnrichedMetadata` is the unit of
/// transformation at `.postEnrich`; richer fields land alongside future hook
/// points. `Sendable` so it can cross into `hook.apply` on any executor.
struct CaptureHookContext {
    let tenantID: UUID
    let url: String
    /// The decrypted install config for the hook (empty for config-less hooks
    /// like `reading-time`). Threaded now so secret-config hooks (a later
    /// slice) need no signature change.
    let config: [String: String]
    var metadata: EnrichedMetadata
}

/// A declarative capture capability. Resolved by `binding` from
/// `CaptureHookRegistry`; the catalog entry's `binding` selects the
/// implementation, exactly as connectors do.
protocol CaptureHook: Sendable {
    /// Catalog `binding` key this hook serves (see `PluginCatalog`).
    var binding: String { get }
    /// The pipeline stage this hook runs at.
    var hookPoint: CaptureHookPoint { get }
    /// Transform the context. Throwing is allowed — the dispatcher isolates
    /// failures so a misbehaving hook never breaks a capture.
    func apply(_ context: CaptureHookContext) async throws -> CaptureHookContext
}
