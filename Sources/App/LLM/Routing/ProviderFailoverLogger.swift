import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-252 — actor that persists `ProviderFailoverNotice` records to
/// `provider_failover_events` for ops dashboards + fleet-wide degradation
/// monitoring. Writes are fire-and-forget from the chat hot path: the
/// caller invokes `record(...)` without awaiting completion, the actor
/// serializes inserts internally.
///
/// Trade-off: a hard server crash between accepting a notice and the
/// DB insert losing one row. Acceptable — telemetry, not transactional
/// data. The row's absence shows up at most as one missing point on a
/// time-series chart.
actor ProviderFailoverLogger {
    private let fluent: Fluent
    private let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    /// Fire-and-forget record. Spawned in an unstructured `Task` so the
    /// chat dispatcher doesn't pay the DB write latency. Failures log
    /// at `.error` but never throw to the caller — a failed insert
    /// must not break the user's chat.
    nonisolated func record(
        notice: ProviderFailoverNotice,
        tenantID: UUID?,
    ) {
        Task { [self] in
            await persist(notice: notice, tenantID: tenantID)
        }
    }

    private func persist(notice: ProviderFailoverNotice, tenantID: UUID?) async {
        let row = ProviderFailoverEvent()
        row.tenantID = tenantID
        row.provider = notice.originalProvider.rawValue
        row.model = notice.originalModel
        row.statusCode = notice.statusCode
        row.errorCode = notice.reasonCode
        row.fallbackProvider = notice.fallbackProvider.rawValue
        row.fallbackModel = notice.fallbackModel
        row.source = notice.source.rawValue
        row.happenedAt = Date()
        do {
            try await row.save(on: fluent.db())
        } catch {
            logger.error("provider_failover_events insert failed: \(error)")
        }
    }
}
