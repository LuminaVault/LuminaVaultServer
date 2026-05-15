import Foundation
import Logging
import LuminaVaultShared
import NIOCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-205 — `VisionEmbedProviderAdapter` wrapping Cohere's image-embedding
/// endpoint (`POST https://api.cohere.com/v2/embed`). Cohere accepts the
/// image as a base64 data URI in the `images` array and returns one
/// embedding per image. Selected at boot when
/// `vision.embed.provider=cohere` and the apiKey is non-empty.
struct CohereImageEmbedAdapter: VisionEmbedProviderAdapter {
    let kind: VisionEmbedProviderKind = .cohere
    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession
    let logger: Logger

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.cohere.com")!,
        model: String = "embed-image-v3.0",
        session: URLSession = .shared,
        logger: Logger,
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.logger = logger
    }

    func embed(image: ByteBuffer, mime: String) async throws -> VisionEmbedUpstreamResult {
        let url = baseURL.appendingPathComponent("v2").appendingPathComponent("embed")
        let bytes = Data(buffer: image)
        let base64 = bytes.base64EncodedString()
        let dataURI = "data:\(mime);base64,\(base64)"

        let payload = CohereEmbedRequest(
            model: model,
            inputType: "image",
            embeddingTypes: ["float"],
            images: [dataURI],
        )
        let encodedPayload: Data
        do {
            encodedPayload = try JSONEncoder().encode(payload)
        } catch {
            throw VisionEmbedProviderError.decode(provider: kind, underlying: error)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encodedPayload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw VisionEmbedProviderError.network(provider: kind, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VisionEmbedProviderError.transient(provider: kind, status: 0, body: nil)
        }
        let status = http.statusCode
        guard (200 ..< 300).contains(status) else {
            let preview = String(data: data.prefix(512), encoding: .utf8)
            if status == 429 || (500 ..< 600).contains(status) {
                logger.error("cohere embed transient \(status): \(preview ?? "<binary>")")
                throw VisionEmbedProviderError.transient(provider: kind, status: status, body: preview)
            }
            logger.error("cohere embed permanent \(status): \(preview ?? "<binary>")")
            throw VisionEmbedProviderError.permanent(provider: kind, status: status, body: preview)
        }

        let decoded: CohereEmbedResponse
        do {
            decoded = try JSONDecoder().decode(CohereEmbedResponse.self, from: data)
        } catch {
            throw VisionEmbedProviderError.decode(provider: kind, underlying: error)
        }

        guard let first = decoded.embeddings.float.first, !first.isEmpty else {
            throw VisionEmbedProviderError.decode(provider: kind, underlying: CohereDecodeError.emptyEmbedding)
        }

        return VisionEmbedUpstreamResult(
            embedding: first,
            model: model,
            sourceWidth: nil,
            sourceHeight: nil,
        )
    }
}

// MARK: - Wire DTOs (Cohere v2/embed)

private struct CohereEmbedRequest: Encodable {
    let model: String
    let inputType: String
    let embeddingTypes: [String]
    let images: [String]

    enum CodingKeys: String, CodingKey {
        case model
        case inputType = "input_type"
        case embeddingTypes = "embedding_types"
        case images
    }
}

private struct CohereEmbedResponse: Decodable {
    let embeddings: CohereEmbeddings
}

private struct CohereEmbeddings: Decodable {
    let float: [[Float]]
}

private enum CohereDecodeError: Error {
    case emptyEmbedding
}
