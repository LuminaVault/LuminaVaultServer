import FluentKit
import Foundation

/// HER-134 — per-tenant monthly token-usage counter for the cost guard.
/// One row per `(tenant_id, year_month)`. `year_month` is `"YYYY-MM"`
/// (UTC). `EmbeddingUsageTracker` upserts on success.
final class EmbeddingUsage: Model, @unchecked Sendable {
    static let schema = "embedding_usage"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "year_month") var yearMonth: String
    @Field(key: "tokens_used") var tokensUsed: Int64
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, yearMonth: String, tokensUsed: Int64) {
        self.tenantID = tenantID
        self.yearMonth = yearMonth
        self.tokensUsed = tokensUsed
    }

    /// `"YYYY-MM"` for a given timestamp in UTC.
    static func yearMonth(for date: Date = .init()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let comps = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 1970, comps.month ?? 1)
    }
}
