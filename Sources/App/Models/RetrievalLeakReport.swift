import FluentKit
import Foundation

/// Weekly per-tenant roll-up of `RetrievalTelemetryEvent` rows — "where is
/// retrieval leaking?" The persisted source of truth for the leak report;
/// `RetrievalLeakReportWorker` writes exactly one row per `(tenant, window)`
/// (UNIQUE index drives idempotency). Optionally mirrored to an
/// `Insight(section: .patterns)` for the iOS Analytics surface.
final class RetrievalLeakReport: Model, TenantModel, @unchecked Sendable {
    static let schema = "retrieval_leak_reports"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "period_start") var periodStart: Date
    @Field(key: "period_end") var periodEnd: Date
    @Field(key: "total_retrievals") var totalRetrievals: Int
    @Field(key: "zero_hit_count") var zeroHitCount: Int
    /// Fraction of retrievals in the window that returned nothing (0.0–1.0).
    @Field(key: "zero_hit_rate") var zeroHitRate: Double
    /// Mean closest-distance across non-zero-hit retrievals; NULL if all zero.
    @OptionalField(key: "mean_top_distance") var meanTopDistance: Double?
    /// `source_path` (optionally `:space_id`) with the worst zero-hit rate.
    @OptionalField(key: "worst_source") var worstSource: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        tenantID: UUID,
        periodStart: Date,
        periodEnd: Date,
        totalRetrievals: Int,
        zeroHitCount: Int,
        zeroHitRate: Double,
        meanTopDistance: Double?,
        worstSource: String?
    ) {
        self.tenantID = tenantID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.totalRetrievals = totalRetrievals
        self.zeroHitCount = zeroHitCount
        self.zeroHitRate = zeroHitRate
        self.meanTopDistance = meanTopDistance
        self.worstSource = worstSource
    }
}
