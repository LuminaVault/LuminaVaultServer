import FluentKit
import Foundation

final class Memory: Model, TenantModel, @unchecked Sendable {
    static let schema = "memories"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "content") var content: String
    @OptionalField(key: "tags") var tags: [String]?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    // HER-147 scoring + access tracking.
    @Field(key: "score") var score: Double
    @Field(key: "access_count") var accessCount: Int64
    @Field(key: "query_hit_count") var queryHitCount: Int64
    @OptionalField(key: "last_accessed_at") var lastAccessedAt: Date?

    /// HER-150 lineage. NULL when the upsert path didn't declare a source
    /// (older rows, direct API writes without context). FK is ON DELETE SET
    /// NULL so a soft-deleted source file doesn't cascade-delete memories
    /// it spawned — the trace just degrades to "source unknown".
    @OptionalField(key: "source_vault_file_id") var sourceVaultFileID: UUID?

    /// HER-207 — optional geo anchor (WGS84 lat/lng + accuracy radius in
    /// metres + reverse-geocoded place label). All four are independently
    /// NULL when the memory was captured without location context.
    @OptionalField(key: "lat") var lat: Double?
    @OptionalField(key: "lng") var lng: Double?
    @OptionalField(key: "accuracy_m") var accuracyM: Double?
    @OptionalField(key: "place_name") var placeName: String?

    init() {
        score = 0
        accessCount = 0
        queryHitCount = 0
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        content: String,
        tags: [String]? = nil,
        sourceVaultFileID: UUID? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        accuracyM: Double? = nil,
        placeName: String? = nil,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.content = content
        self.tags = tags
        self.sourceVaultFileID = sourceVaultFileID
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.placeName = placeName
        score = 0
        accessCount = 0
        queryHitCount = 0
    }
}
