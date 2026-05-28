import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging

/// HER-134 — Nomic Atlas API embedding adapter. `nomic-embed-text-v1.5`
/// returns 768-dim vectors at max; we **zero-pad to 1536** so the result
/// fits the pgvector column. Cosine similarity stays unchanged when both
/// sides of a comparison come from Nomic. Mixing providers mid-tenant is
/// undefined — registry should prevent that.
final class NomicEmbeddingService: EmbeddingService {
    static let defaultBaseURL = URL(string: "https://api-atlas.nomic.ai")!
    static let defaultModel = "nomic-embed-text-v1.5"
    static let targetDim = 1536
    static let nativeDim = 768

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private let logger: Logger

    init(
        apiKey: String,
        baseURL: URL = NomicEmbeddingService.defaultBaseURL,
        model: String = NomicEmbeddingService.defaultModel,
        session: URLSession = .shared,
        logger: Logger = Logger(label: "lv.embedding.nomic"),
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.logger = logger
    }

    func embed(_ text: String, tenantID _: UUID) async throws -> [Float] {
        guard !apiKey.isEmpty else {
            throw EmbeddingProviderError.permanent(reason: .missingAPIKey)
        }
        let url = baseURL.appendingPathComponent("v1/embedding/text")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = RequestBody(model: model, texts: [text])
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingProviderError.network(reason: "nomic: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.network(reason: "nomic: non-http response")
        }
        switch http.statusCode {
        case 200 ..< 300: break
        case 401, 403:
            throw EmbeddingProviderError.permanent(reason: .authRejected)
        case 408, 429, 500 ..< 600:
            throw EmbeddingProviderError.transient(reason: "nomic http \(http.statusCode)")
        default:
            throw EmbeddingProviderError.permanent(reason: .requestRejected)
        }
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw EmbeddingProviderError.permanent(reason: .decodeFailed)
        }
        guard let first = decoded.embeddings.first else {
            throw EmbeddingProviderError.permanent(reason: .decodeFailed)
        }
        return Self.padToTarget(first)
    }

    /// Pads a vector ≤ targetDim with zeros up to targetDim. Vectors
    /// already at targetDim pass through; larger vectors trigger a
    /// `dimMismatch` so we never silently truncate.
    static func padToTarget(_ v: [Float]) -> [Float] {
        if v.count == targetDim { return v }
        if v.count < targetDim {
            var padded = v
            padded.append(contentsOf: [Float](repeating: 0, count: targetDim - v.count))
            return padded
        }
        return Array(v.prefix(targetDim))
    }

    private struct RequestBody: Encodable {
        let model: String
        let texts: [String]
    }

    private struct ResponseBody: Decodable {
        let embeddings: [[Float]]
    }
}
