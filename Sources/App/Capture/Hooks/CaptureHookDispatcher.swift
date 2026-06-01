import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// HER-54 (Slice 1) — runs the tenant's enabled `.captureHook` plugins at a
/// given `CaptureHookPoint`. The engine the capture pipeline calls into.
///
/// Resolution mirrors connector sync (`PluginService.sync`): read the tenant's
/// enabled `PluginInstall` rows, map each to its static `PluginCatalog` entry,
/// keep the ones whose `capabilityKind == .captureHook`, resolve the
/// implementation by `binding` from `CaptureHookRegistry`, and run those that
/// match `point` in deterministic slug order.
///
/// ## Failure isolation
/// A hook that throws is logged and skipped — a capture must never break
/// because a plugin misbehaved. Same discipline as `applyJinaIfShallow` and
/// the catch-all in `URLEnrichmentService.enrichAndRewrite`. A failed install
/// query also degrades to the unchanged context.
///
/// Slice 1 hooks are config-less, so `CaptureHookContext.config` is empty. When
/// a later slice adds secret-config hooks, decrypt here via `SecretBox` (as
/// `PluginService.openConfig` does) before invoking the hook.
struct CaptureHookDispatcher {
    /// Optional so the pure `dispatch` path is constructible without a database
    /// in unit tests. `run` no-ops to the unchanged context when nil.
    let fluent: Fluent?
    let registry: CaptureHookRegistry
    let logger: Logger

    /// Read the tenant's enabled installs, then dispatch. The DB read lives
    /// here; the transformation logic is in `dispatch` so it stays unit-testable
    /// without a database (the rest of the plugin suite avoids DB-backed tests
    /// to dodge the HER-310 AsyncKit teardown crash).
    func run(point: CaptureHookPoint, context: CaptureHookContext) async -> CaptureHookContext {
        guard let fluent else { return context }
        let slugs: [String]
        do {
            slugs = try await PluginInstall.query(on: fluent.db())
                .filter(\.$tenantID == context.tenantID)
                .filter(\.$status == PluginInstallState.enabled)
                .all()
                .map(\.pluginSlug)
        } catch {
            logger.error(
                "capture-hook dispatch query failed tenant=\(context.tenantID) point=\(point.rawValue): \(error)",
            )
            return context
        }
        return await dispatch(point: point, installedSlugs: slugs, context: context)
    }

    /// Pure dispatch: run the `.captureHook` plugins among `installedSlugs` that
    /// match `point`, in deterministic slug order, transforming the context.
    /// Failure-isolated — a hook that throws is logged and skipped. No DB.
    func dispatch(
        point: CaptureHookPoint,
        installedSlugs: [String],
        context: CaptureHookContext,
    ) async -> CaptureHookContext {
        var ctx = context
        for slug in installedSlugs.sorted() {
            guard let entry = PluginCatalog.entry(slug: slug),
                  entry.dto.capabilityKind == .captureHook,
                  let hook = registry.hook(binding: entry.binding),
                  hook.hookPoint == point
            else { continue }

            do {
                ctx = try await hook.apply(ctx)
            } catch {
                logger.warning(
                    "capture-hook \(slug) failed at \(point.rawValue) tenant=\(context.tenantID); skipping: \(error)",
                )
            }
        }
        return ctx
    }
}
