import Foundation
import Hummingbird

// HER-213: VisionEmbedResponse was pruned from LuminaVaultShared v0.11.0
// per the wire-types-only boundary (model + dimensions are server-internal
// reflection of which provider answered). Lives server-side now.

struct VisionEmbedResponse: Codable, Sendable {
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
