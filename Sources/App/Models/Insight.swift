import FluentKit
import Foundation
import LuminaVaultShared

/// HER-37 Slice D — persisted proactive finding row. Two flavours:
///
/// - **Synthesis** (`thisWeek` / `thisMonth`): `periodStart`/`periodEnd`
///   demarcate the analytical window; cron writes one row per window.
/// - **Pattern / Contradiction / Connection**: `periodStart` and
///   `periodEnd` are nil; rows accumulate as the daily pattern job
///   surfaces surprising connections.
final class Insight: Model, TenantModel, @unchecked Sendable {
    static let schema = "insights"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "section") var section: String
    @Field(key: "headline") var headline: String
    @Field(key: "summary") var summary: String
    @Field(key: "source_memory_ids") var sourceMemoryIDs: [UUID]
    @OptionalField(key: "period_start") var periodStart: Date?
    @OptionalField(key: "period_end") var periodEnd: Date?
    @OptionalField(key: "dismissed_at") var dismissedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {
        sourceMemoryIDs = []
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        section: InsightSection,
        headline: String,
        summary: String,
        sourceMemoryIDs: [UUID] = [],
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        dismissedAt: Date? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.section = section.rawValue
        self.headline = headline
        self.summary = summary
        self.sourceMemoryIDs = sourceMemoryIDs
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.dismissedAt = dismissedAt
    }

    /// Convert to the wire DTO. Unknown section strings (defensive
    /// against schema drift) coerce to `.patterns` — the safest bucket
    /// for the iOS surface since it's always rendered.
    func toDTO() throws -> InsightDTO {
        try InsightDTO(
            id: requireID(),
            headline: headline,
            summary: summary,
            section: InsightSection(rawValue: section) ?? .patterns,
            createdAt: createdAt ?? Date(),
            sourceMemoryIDs: sourceMemoryIDs,
            dismissed: dismissedAt != nil,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
    }
}
