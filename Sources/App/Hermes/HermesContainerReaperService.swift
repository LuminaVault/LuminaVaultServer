import Foundation
import Logging
import ServiceLifecycle

/// Periodic reaper for idle per-tenant Hermes containers.
///
/// `HermesContainerManager.evictIdle()` has existed since HER-240a, is
/// documented as "called periodically by a background service in
/// `App+build`", and had no caller. Nothing ever reaped a container.
///
/// The consequences compound. Tenant containers run
/// `--restart=unless-stopped`, so every one ever spawned stayed up across
/// host reboots, held its slot in a port pool of `portRangeEnd -
/// portRangeStart` (500 in production), and held whatever memory its last
/// session allocated. `ensureRunning` throws `.portRangeExhausted` once the
/// pool is full, at which point no new tenant can be provisioned at all —
/// a cliff, not a slope, and one nothing would have explained.
///
/// Unlike the lapse archiver and profile reconciler this runs on a fixed
/// interval rather than a wall-clock hour: the thing it reacts to is an idle
/// TTL measured in seconds, so a nightly pass would leave a container idle
/// for up to a day. The default interval is a quarter of the TTL, floored at
/// a minute, which bounds the overshoot to 25% of the configured idle window.
///
/// A run that throws is logged and the loop continues — a DB blip must not
/// tear the process down, and the next tick retries.
actor HermesContainerReaperService: Service {
    private let manager: HermesContainerManager
    private let interval: Duration
    private let logger: Logger

    init(manager: HermesContainerManager, intervalSeconds: Int, logger: Logger) {
        self.manager = manager
        interval = .seconds(max(60, intervalSeconds))
        self.logger = logger
    }

    /// The cadence the reaper runs at for a given idle TTL.
    static func intervalSeconds(idleTTLSeconds: Int) -> Int {
        max(60, idleTTLSeconds / 4)
    }

    func run() async throws {
        // HER-310 — `app.test(.router)` can spin the ServiceGroup up and
        // graceful-shut it down immediately. Probing the DB in that window
        // races `Databases.shutdownAsync()` and trips a non-throwing
        // precondition, killing the test binary on exit. Same guard as
        // `HermesProfileReconcilerService`.
        guard !Task.isShuttingDownGracefully, !Task.isCancelled else { return }
        logger.info("hermes.container.reaper started interval_s=\(interval)")
        while !Task.isShuttingDownGracefully, !Task.isCancelled {
            do {
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: self.interval)
                }
            } catch {
                return
            }
            guard !Task.isCancelled, !Task.isShuttingDownGracefully else { return }
            do {
                let evicted = try await manager.evictIdle()
                if evicted > 0 {
                    logger.info("hermes.container.reaper evicted=\(evicted)")
                }
            } catch {
                logger.warning("hermes.container.reaper error \(error)")
            }
        }
    }
}
