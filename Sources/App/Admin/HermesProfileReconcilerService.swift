import Foundation
import Logging
import ServiceLifecycle

/// HER-29 — daily scheduled wrapper around `HermesProfileReconciler`. Mirrors
/// the `LapseArchiverService` pattern: a `ServiceLifecycle` actor that sleeps
/// until the next target wall-clock window, runs `reconcile()`, logs the
/// summary, and loops. Errors are logged and the loop continues — a single
/// bad run never tears the process down.
///
/// Target window: 04:00 UTC, offset one hour from the lapse archiver (03:00
/// UTC) so the two jobs don't pile concurrent DB pressure on Postgres.
actor HermesProfileReconcilerService: Service {
    private let reconciler: HermesProfileReconciler
    private let logger: Logger
    private let targetHourUTC: Int

    init(reconciler: HermesProfileReconciler, logger: Logger, targetHourUTC: Int = 4) {
        self.reconciler = reconciler
        self.logger = logger
        self.targetHourUTC = targetHourUTC
    }

    func run() async throws {
        // HER-226 — surface gateway reachability at startup so the
        // first log line operators see on boot answers "is Hermes up?".
        do {
            let h = try await reconciler.health()
            logger.info(
                "hermes.reconciler.service started gateway_reachable=\(h.gatewayReachable) gateway_latency_ms=\(h.gatewayLatencyMs.map(String.init) ?? "nil")",
            )
        } catch {
            logger.info("hermes.reconciler.service started (health probe failed: \(error))")
        }
        while !Task.isShuttingDownGracefully, !Task.isCancelled {
            do {
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(self.secondsUntilNextRun(now: Date())))
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !Task.isShuttingDownGracefully else { return }
            do {
                let summary = try await reconciler.reconcile()
                logger.info(
                    "hermes.reconciler.service ran scanned=\(summary.usersScanned) created=\(summary.profilesCreated) recovered=\(summary.profilesRecovered) ok=\(summary.profilesAlreadyOK) failures=\(summary.failures.count)",
                )
            } catch {
                logger.warning("hermes.reconciler.service error \(error)")
            }
        }
    }

    private func secondsUntilNextRun(now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var next = calendar.dateComponents([.year, .month, .day], from: now)
        next.hour = targetHourUTC
        next.minute = 0
        next.second = 0
        let today = calendar.date(from: next) ?? now.addingTimeInterval(3600)
        let target = today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86400)
        return max(1, Int(target.timeIntervalSince(now)))
    }
}
