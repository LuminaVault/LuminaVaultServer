import Foundation
import LuminaVaultShared
import NIOCore

/// HER-205 — test-only adapter returning a deterministic embedding without
/// any network. Wired by `App+build` only when
/// `vision.embed.provider=stub`. Tests pin the embedding via
/// `vision.embed.stub.dim` (length) so they can assert exact wire shape.
struct StubVisionEmbedAdapter: VisionEmbedProviderAdapter {
    let kind: VisionEmbedProviderKind = .stub
    let dim: Int
    let fill: Float
    let model: String
    let sourceWidth: Int?
    let sourceHeight: Int?

    init(
        dim: Int = 1024,
        fill: Float = 0.1,
        model: String = "stub-clip",
        sourceWidth: Int? = 768,
        sourceHeight: Int? = 768,
    ) {
        self.dim = dim
        self.fill = fill
        self.model = model
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    func embed(image _: ByteBuffer, mime _: String) async throws -> VisionEmbedUpstreamResult {
        VisionEmbedUpstreamResult(
            embedding: Array(repeating: fill, count: dim),
            model: model,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
        )
    }
}
