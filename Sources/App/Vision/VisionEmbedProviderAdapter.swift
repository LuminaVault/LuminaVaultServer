import Foundation
import LuminaVaultShared
import NIOCore

/// HER-205 — uniform interface every upstream image-embedding provider
/// implements. v1 ships with `CohereImageEmbedAdapter`; OpenAI / Replicate
/// / Hermes-vision drop in via additional conformances.
///
/// Implementations:
/// - MUST translate the provider's native wire shape to a normalized
///   `VisionEmbedUpstreamResult`.
/// - MUST throw `VisionEmbedProviderError` (never bare `URLError` /
///   decode errors) so the service layer can map to HTTP status cleanly.
/// - SHOULD NOT retry internally — the service layer owns retry policy.
protocol VisionEmbedProviderAdapter: Sendable {
    var kind: VisionEmbedProviderKind { get }

    /// Send a single image-embedding request. `image` carries the raw
    /// bytes; `mime` is the verbatim `Content-Type` the controller
    /// validated upstream.
    func embed(image: ByteBuffer, mime: String) async throws -> VisionEmbedUpstreamResult
}

/// Stable identifier per provider. Map 1:1 to the `vision.embed.provider`
/// env knob — `vision.embed.provider=cohere` selects `.cohere`.
enum VisionEmbedProviderKind: String, Sendable, CaseIterable {
    case cohere
    case openai
    case replicate
    case hermesVision
    case stub
}

/// Normalized result from any `VisionEmbedProviderAdapter`. The service
/// layer pads / truncates `embedding` to `targetDim` before responding
/// or writing to `memory_embeddings`.
struct VisionEmbedUpstreamResult: Sendable {
    /// Raw embedding from the provider. Length is provider-defined —
    /// service normalizes to the target dim (1536 for pgvector).
    let embedding: [Float]
    let model: String
    /// Decoded image dimensions, if the provider returns them. Some
    /// providers don't echo dims; the controller still reports them via
    /// best-effort decode of the request headers / image header bytes.
    let sourceWidth: Int?
    let sourceHeight: Int?
}

/// Typed errors thrown by adapters. The controller maps these to HTTP
/// status codes; the service layer can also use `.isRecoverable` to
/// decide whether to fail over (currently no-op — single provider).
enum VisionEmbedProviderError: Error {
    case transient(provider: VisionEmbedProviderKind, status: Int, body: String?)
    case permanent(provider: VisionEmbedProviderKind, status: Int, body: String?)
    case network(provider: VisionEmbedProviderKind, underlying: any Error)
    case decode(provider: VisionEmbedProviderKind, underlying: any Error)

    var isRecoverable: Bool {
        switch self {
        case .transient, .network: true
        case .permanent, .decode: false
        }
    }
}
