import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging

/// HER-134 — text-embedding-3-small backed by OpenAI's `/v1/embeddings`.
/// Returns 1536-dim vectors (column-pinned via `dimensions` param). The
/// `usage.total_tokens` field is captured by an out-of-band callback so
/// `EmbeddingUsageTracker` can attribute spend per tenant without taking
/// a dependency on the service here.
final class OpenAIEmbeddingService: EmbeddingService {
    static let defaultBaseURL = URL(string: "https://api.openai.com")!
    static let defaultModel = "text-embedding-3-small"
    static let targetDim = 1536

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private let logger: Logger
    private let usageCallback: (@Sendable (UUID, Int64) async -> Void)?

    init(
        apiKey: String,
        baseURL: URL = OpenAIEmbeddingService.defaultBaseURL,
        model: String = OpenAIEmbeddingService.defaultModel,
        session: URLSession = .shared,
        logger: Logger = Logger(label: "lv.embedding.openai"),
        usageCallback: (@Sendable (UUID, Int64) async -> Void)? = nil,
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.logger = logger
        self.usageCallback = usageCallback
    }

    func embed(_ text: String, tenantID: UUID) async throws -> [Float] {
        guard !apiKey.isEmpty else {
            throw EmbeddingProviderError.permanent(reason: .missingAPIKey)
        }
        let url = baseURL.appendingPathComponent("v1/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = RequestBody(model: model, input: text, dimensions: Self.targetDim, encodingFormat: "float")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingProviderError.network(reason: "openai: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.network(reason: "openai: non-http response")
        }
        switch http.statusCode {
        case 200 ..< 300: break
        case 401, 403:
            throw EmbeddingProviderError.permanent(reason: .authRejected)
        case 408, 429, 500 ..< 600:
            throw EmbeddingProviderError.transient(reason: "openai http \(http.statusCode)")
        default:
            throw EmbeddingProviderError.permanent(reason: .requestRejected)
        }
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw EmbeddingProviderError.permanent(reason: .decodeFailed)
        }
        guard let first = decoded.data.first else {
            throw EmbeddingProviderError.permanent(reason: .decodeFailed)
        }
        guard first.embedding.count == Self.targetDim else {
            throw EmbeddingProviderError.dimMismatch(expected: Self.targetDim, got: first.embedding.count)
        }
        if let cb = usageCallback, let tokens = decoded.usage?.total_tokens {
            await cb(tenantID, Int64(tokens))
        }
        return first.embedding
    }

    // MARK: - Wire format

    private struct RequestBody: Encodable {
        let model: String
        let input: String
        let dimensions: Int
        let encodingFormat: String

        enum CodingKeys: String, CodingKey {
            case model, input, dimensions
            case encodingFormat = "encoding_format"
        }
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable { let embedding: [Float] }
        struct Usage: Decodable { let total_tokens: Int }
        let data: [Item]
        let usage: Usage?
    }
}
