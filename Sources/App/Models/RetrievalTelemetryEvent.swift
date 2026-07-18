import FluentKit
import Foundation

/// Content-free record of one pgvector retrieval, captured to measure
/// retrieval *quality* (the `RouteTelemetry`/OTel spans already cover latency
/// and count). One row per grounding search — local-reply chat, `/v1/query`,
/// or the agentic `session_search` tool. Distances are cosine (`<=>`); lower
/// is a closer match. A zero-hit search stores `hitCount == 0` and NULL
/// distances. Rows carry no query text or memory content — only shape.
///
/// Written off the hot path by `RetrievalTelemetryWorker` (batched INSERT) and
/// pruned after 90 days by `AnalyticsMaintenanceService`. Aggregated weekly by
/// `RetrievalLeakReportWorker`.
final class RetrievalTelemetryEvent: Model, TenantModel, @unchecked Sendable {
    static let schema = "retrieval_telemetry_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    /// `local_reply` | `query` | `agentic_search` (see `RetrievalSourcePath`).
    @Field(key: "source_path") var sourcePath: String
    /// Present only when the search was Space-scoped (agentic `session_search`
    /// with a `space` arg). NULL = unscoped (the default, current behavior).
    @OptionalField(key: "space_id") var spaceID: UUID?
    @Field(key: "hit_count") var hitCount: Int
    /// Denormalized `hitCount == 0` for cheap aggregation.
    @Field(key: "zero_hit") var zeroHit: Bool
    /// Closest (minimum) cosine distance among the returned hits; NULL if none.
    @OptionalField(key: "top_distance") var topDistance: Double?
    @OptionalField(key: "mean_distance") var meanDistance: Double?
    @Field(key: "limit_requested") var limitRequested: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(_ sample: RetrievalTelemetrySample) {
        tenantID = sample.tenantID
        sourcePath = sample.sourcePath.rawValue
        spaceID = sample.spaceID
        hitCount = sample.hitCount
        zeroHit = sample.hitCount == 0
        topDistance = sample.topDistance
        meanDistance = sample.meanDistance
        limitRequested = sample.limitRequested
    }
}
