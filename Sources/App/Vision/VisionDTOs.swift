import Foundation
import Hummingbird

// HER-213: VisionEmbedResponse was pruned from LuminaVaultShared v0.11.0
// per the wire-types-only boundary (model + dimensions are server-internal
// reflection of which provider answered). Lives server-side now.

struct VisionEmbedResponse: Codable {
    let embedding: [Float]
    let dim: Int
    let model: String
    let sourceWidth: Int
    let sourceHeight: Int
    enum CodingKeys: String, CodingKey {
        case embedding, dim, model
        case sourceWidth = "source_width"
        case sourceHeight = "source_height"
    }

    init(embedding: [Float], dim: Int, model: String, sourceWidth: Int, sourceHeight: Int) {
        self.embedding = embedding; self.dim = dim; self.model = model
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
    }
}

extension VisionEmbedResponse: ResponseEncodable {}

/// `POST /v1/vision/search` — the memories nearest a picture.
///
/// `distance` is pgvector's cosine distance, so smaller is closer. It is
/// surfaced rather than hidden because an image search has no lexical anchor
/// to sanity-check against: without the number, a result set of loosely
/// related memories looks identical to a good one.
struct VisionSearchResponse: Codable {
    let hits: [VisionSearchHit]
    /// Which provider answered, for the same reason the embed endpoint
    /// returns it — results are only comparable within one model.
    let model: String
}

struct VisionSearchHit: Codable {
    let id: UUID
    let content: String
    let distance: Float
    let createdAt: Date?
}

extension VisionSearchResponse: ResponseEncodable {}
