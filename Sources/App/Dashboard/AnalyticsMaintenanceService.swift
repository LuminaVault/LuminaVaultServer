import FluentKit
import HummingbirdFluent
import Logging
import ServiceLifecycle
import SQLKit

/// Keeps usage-intelligence storage bounded without adding table-wide deletes
/// to interactive memory, chat, or telemetry writes.
actor AnalyticsMaintenanceService: Service {
    let fluent: Fluent
    let logger: Logger
    let tickInterval: Duration

    init(
        fluent: Fluent,
        logger: Logger = Logger(label: "lv.analytics.maintenance"),
        tickInterval: Duration = .seconds(24 * 60 * 60)
    ) {
        self.fluent = fluent
        self.logger = logger
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("analytics maintenance started", metadata: ["tick": "\(tickInterval)"])
        while !Task.isCancelled {
            do {
                try await runOnce()
            } catch {
                logger.error("analytics maintenance failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    func runOnce() async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM analytics_events WHERE occurred_at < NOW() - interval '90 days'").run()
        try await sql.raw("DELETE FROM analytics_daily_rollups WHERE day < CURRENT_DATE - interval '13 months'").run()
        // Retrieval telemetry is raw per-event; the weekly leak reports are the
        // durable roll-up, so events past 90 days can be dropped.
        try await sql.raw("DELETE FROM retrieval_telemetry_events WHERE created_at < NOW() - interval '90 days'").run()
    }
}
