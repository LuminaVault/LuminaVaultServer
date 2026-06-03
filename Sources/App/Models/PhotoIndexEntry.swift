import FluentKit
import Foundation

/// Apple Photos derived-text index row (schema "photo_index", M81).
///
/// Mirrors the `Memory` model's treatment of pgvector: the `embedding`
/// `vector(1536)` column is NOT declared as a Fluent field — Fluent has no
/// native pgvector encoder — so it is written/read via raw SQL in
/// `PhotoIndexRepository`. Everything else (metadata + derived text + scene
/// tags) is a normal Fluent field.
///
/// PRIVACY: this row only ever holds OCR text, on-device scene labels, and
/// metadata — never pixel data.
final class PhotoIndexEntry: Model, @unchecked Sendable {
    static let schema = "photo_index"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    /// `PHAsset.localIdentifier` — the upsert key (with tenant_id).
    @Field(key: "asset_local_id") var assetLocalID: String
    @OptionalField(key: "taken_at") var takenAt: Date?
    @Field(key: "is_screenshot") var isScreenshot: Bool
    @OptionalField(key: "ocr_text") var ocrText: String?
    @OptionalField(key: "scene_tags") var sceneTags: [String]?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {
        isScreenshot = false
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        assetLocalID: String,
        takenAt: Date? = nil,
        isScreenshot: Bool = false,
        ocrText: String? = nil,
        sceneTags: [String]? = nil,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.assetLocalID = assetLocalID
        self.takenAt = takenAt
        self.isScreenshot = isScreenshot
        self.ocrText = ocrText
        self.sceneTags = sceneTags
    }
}
