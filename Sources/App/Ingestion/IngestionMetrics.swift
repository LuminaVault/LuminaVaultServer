import Foundation
import Metrics

enum IngestionMetrics {
    static let claimed = Counter(label: "luminavault.ingestion.claimed")
    static let completed = Counter(label: "luminavault.ingestion.completed")
    static let failed = Counter(label: "luminavault.ingestion.failed")
    static let retried = Counter(label: "luminavault.ingestion.retried")
    static let deduplicated = Counter(label: "luminavault.ingestion.deduplicated")
    static let apnsFailures = Counter(label: "luminavault.ingestion.apns.failures")
    static let queueLatency = Timer(label: "luminavault.ingestion.queue_latency")

    static func recordQueueLatency(createdAt: Date?) {
        guard let createdAt else { return }
        queueLatency.recordNanoseconds(Int64(max(0, Date().timeIntervalSince(createdAt)) * 1_000_000_000))
    }
}
