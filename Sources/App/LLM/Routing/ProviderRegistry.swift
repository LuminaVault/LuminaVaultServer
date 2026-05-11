import Foundation
import Logging

/// HER-165 — runtime adapter map. Constructed once at boot in
/// `App+build` and populated with every adapter the deployment has
/// credentials for. `RoutedLLMTransport` queries it to resolve a
/// `ProviderKind` decision from `ModelRouter` into a callable adapter.
///
/// Actor so registration + lookup never race. Read-heavy workload — the
/// registry is written exactly once at boot and read on every chat call.
actor ProviderRegistry {
    private var adapters: [ProviderKind: any ProviderAdapter] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Boot-time convenience: seed the registry with adapters known at
    /// construction. `buildRouter` is currently synchronous, so we can't
    /// `await register(...)` from boot — the seed list is wired through
    /// this init instead. Late registration still goes through `register`.
    init(adapters: [any ProviderAdapter], logger: Logger) {
        self.logger = logger
        for adapter in adapters {
            self.adapters[adapter.kind] = adapter
            logger.info("provider registered: \(adapter.kind.rawValue)")
        }
    }

    /// Idempotent. Re-registering the same kind overwrites the previous
    /// entry — useful for tests that swap a stub in mid-suite.
    func register(_ adapter: any ProviderAdapter) {
        adapters[adapter.kind] = adapter
        logger.info("provider registered: \(adapter.kind.rawValue)")
    }

    func adapter(for kind: ProviderKind) -> (any ProviderAdapter)? {
        adapters[kind]
    }

    /// Snapshot of the registered kinds — useful for observability /
    /// startup logging. Order is implementation-defined; don't rely on it.
    func registered() -> [ProviderKind] {
        Array(adapters.keys)
    }
}
