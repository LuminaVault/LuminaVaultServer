import FluentKit
import Foundation

/// Time-series health data point. Generic schema — `eventType` discriminates
/// between steps / sleep / weight / hr_bpm / blood_oxygen / etc. Numeric
/// values use `valueNumeric`; text-shaped values (e.g. "sleep_quality":
/// "deep") use `valueText`. JSONB metadata for source-specific extras.
///
/// Indexed on `(tenant_id, event_type, recorded_at DESC)` for typical
/// "last N events of type T for user U" queries. When row count crosses
/// ~10M, evaluate Postgres native partitioning by `recorded_at` month.
/// TimescaleDB hypertables are the obvious next step but require an
/// image swap (see docs/integration.md).
final class HealthEvent: Model, TenantModel, @unchecked Sendable {
    static let schema = "health_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "event_type") var eventType: String
    @OptionalField(key: "value_numeric") var valueNumeric: Double?
    @OptionalField(key: "value_text") var valueText: String?
    @OptionalField(key: "unit") var unit: String?
    @Field(key: "recorded_at") var recordedAt: Date
    @OptionalField(key: "source") var source: String?
    @OptionalField(key: "metadata") var metadata: [String: String]?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        eventType: String,
        valueNumeric: Double? = nil,
        valueText: String? = nil,
        unit: String? = nil,
        recordedAt: Date,
        source: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.eventType = eventType
        self.valueNumeric = valueNumeric
        self.valueText = valueText
        self.unit = unit
        self.recordedAt = recordedAt
        self.source = source
        self.metadata = metadata
    }
}
