import Foundation
import Metrics

enum WorkflowMetrics {
    static let queued = Counter(label: "luminavault.workflow.queued")
    static let deduplicated = Counter(label: "luminavault.workflow.deduplicated")
    static let claimed = Counter(label: "luminavault.workflow.claimed")
    static let completed = Counter(label: "luminavault.workflow.completed")
    static let failed = Counter(label: "luminavault.workflow.failed")
    static let paused = Counter(label: "luminavault.workflow.paused")
    static let cancelled = Counter(label: "luminavault.workflow.cancelled")
    static let approvalsRequired = Counter(label: "luminavault.workflow.approvals_required")
    static let freeFallbacks = Counter(label: "luminavault.workflow.free_fallbacks")
    static let eventWriteFailures = Counter(label: "luminavault.workflow.event_write_failures")
    static let managedSpendUsdMicros = Recorder(label: "luminavault.workflow.managed_spend_usd_micros")
    static let queueLatency = Timer(
        label: "luminavault.workflow.queue_latency",
        dimensions: [("unit", "s")]
    )

    static func recordQueueLatency(createdAt: Date?) {
        guard let createdAt else { return }
        queueLatency.recordNanoseconds(Int64(max(0, Date().timeIntervalSince(createdAt)) * 1_000_000_000))
    }
}
