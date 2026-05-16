import Foundation

// HER-213: server-local Memory wire-types.
//
// LuminaVaultShared v0.11.0 pruned MemoryUpsertRequest entirely and stripped
// the HER-207 geo fields (lat/lng/accuracyM/placeName) from MemoryDTO. The
// iOS client still expects the geo-bearing shape on /v1/memory/list and
// /v1/memory/upsert, so we shadow Shared with the full-fidelity types until
// a follow-up Shared release restores them. Same-named locals shadow the
// imported types within this target, so server response payloads keep the
// wire format the client already decodes.

// MARK: - Upsert

struct MemoryUpsertRequest: Codable, Sendable {
    let content: String
    /// HER-207 — optional geo anchor. All four are nil for memories
    /// captured without location (default), set together when the client
    /// supplies a MapKit reverse-geocoded coordinate. `accuracyM` is the
    /// radius of the GPS fix in metres; `placeName` is the human label.
    let lat: Double?
    let lng: Double?
    let accuracyM: Double?
    let placeName: String?
    init(
        content: String,
        lat: Double? = nil,
        lng: Double? = nil,
        accuracyM: Double? = nil,
        placeName: String? = nil
    ) {
        self.content = content
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.placeName = placeName
    }
}

// MARK: - List / read

struct MemoryDTO: Codable, Sendable {
    let id: UUID
    let content: String
    let tags: [String]
    let createdAt: Date?
    /// HER-207 geo anchor (see `MemoryUpsertRequest` for field semantics).
    let lat: Double?
    let lng: Double?
    let accuracyM: Double?
    let placeName: String?
    init(
        id: UUID,
        content: String,
        tags: [String],
        createdAt: Date? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        accuracyM: Double? = nil,
        placeName: String? = nil
    ) {
        self.id = id
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.placeName = placeName
    }
}

struct MemoryListResponse: Codable, Sendable {
    let memories: [MemoryDTO]
    let limit: Int
    let offset: Int
    init(memories: [MemoryDTO], limit: Int, offset: Int) {
        self.memories = memories
        self.limit = limit
        self.offset = offset
    }
}
