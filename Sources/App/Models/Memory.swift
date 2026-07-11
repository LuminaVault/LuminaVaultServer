import FluentKit
import Foundation
import LuminaVaultShared

final class Memory: Model, TenantModel, @unchecked Sendable {
    static let schema = "memories"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "content") var content: String
    @OptionalField(key: "created_by_user_id") var createdByUserID: UUID?
    @OptionalField(key: "updated_by_user_id") var updatedByUserID: UUID?
    @OptionalField(key: "tags") var tags: [String]?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    // HER-147 scoring + access tracking.
    @Field(key: "score") var score: Double
    @Field(key: "access_count") var accessCount: Int64
    @Field(key: "query_hit_count") var queryHitCount: Int64
    @OptionalField(key: "last_accessed_at") var lastAccessedAt: Date?
    @OptionalField(key: "last_reviewed_at") var lastReviewedAt: Date?
    @Field(key: "review_count") var reviewCount: Int64

    /// HER-150 lineage. NULL when the upsert path didn't declare a source
    /// (older rows, direct API writes without context). FK is ON DELETE SET
    /// NULL so a soft-deleted source file doesn't cascade-delete memories
    /// it spawned — the trace just degrades to "source unknown".
    @OptionalField(key: "source_vault_file_id") var sourceVaultFileID: UUID?

    /// HER-105 — optional Space the memory was filed into. NULL when the
    /// capture was unfiled. FK is ON DELETE SET NULL so deleting a Space
    /// leaves its memories intact (they just drop back to "unfiled").
    @OptionalField(key: "space_id") var spaceID: UUID?

    /// HER-207 — optional geo anchor (WGS84 lat/lng + accuracy radius in
    /// metres + reverse-geocoded place label). All four are independently
    /// NULL when the memory was captured without location context.
    @OptionalField(key: "lat") var lat: Double?
    @OptionalField(key: "lng") var lng: Double?
    @OptionalField(key: "accuracy_m") var accuracyM: Double?
    @OptionalField(key: "place_name") var placeName: String?

    /// HER-290 — moderation state. See `MemoryReviewState` in LuminaVaultShared
    /// for the legal values (auto | pending | approved | rejected). Rows
    /// existing before M53 get backfilled to "auto" via the migration default;
    /// kb-compile-produced rows default to "pending" via the service path.
    @Field(key: "review_state") var reviewState: String

    @Field(key: "origin_kind") var originKind: String
    @OptionalField(key: "origin_source_id") var originSourceID: String?
    @OptionalField(key: "origin_provider") var originProvider: String?
    @OptionalField(key: "origin_model") var originModel: String?
    @OptionalField(key: "origin_conversation_message_id") var originConversationMessageID: UUID?

    init() {
        score = 0
        accessCount = 0
        queryHitCount = 0
        reviewCount = 0
        reviewState = "auto"
        originKind = MemorySourceKindDTO.legacy.rawValue
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        content: String,
        tags: [String]? = nil,
        sourceVaultFileID: UUID? = nil,
        spaceID: UUID? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        accuracyM: Double? = nil,
        placeName: String? = nil,
        reviewState: String = "auto",
        originKind: String = MemorySourceKindDTO.legacy.rawValue,
        originSourceID: String? = nil,
        originProvider: String? = nil,
        originModel: String? = nil,
        originConversationMessageID: UUID? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.content = content
        self.tags = tags
        self.sourceVaultFileID = sourceVaultFileID
        self.spaceID = spaceID
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.placeName = placeName
        self.reviewState = reviewState
        self.originKind = originKind
        self.originSourceID = originSourceID
        self.originProvider = originProvider
        self.originModel = originModel
        self.originConversationMessageID = originConversationMessageID
        score = 0
        accessCount = 0
        queryHitCount = 0
        reviewCount = 0
    }
}
