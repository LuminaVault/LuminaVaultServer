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
///
/// Also backs `EmbeddingProviderKind.openRouter`: OpenRouter serves the same
/// wire format at `https://openrouter.ai/api/v1/embeddings` and accepts
/// `dimensions` + `encoding_format`, so only the base URL, model slug
/// (`openai/text-embedding-3-small`) and `providerLabel` differ.
final class OpenAIEmbeddingService: EmbeddingService {
    static let defaultBaseURL = URL(string: "https://api.openai.com")!
    static let defaultModel = "text-embedding-3-small"
    static let openRouterBaseURL = URL(string: "https://openrouter.ai/api")!
    static let openRouterModel = "openai/text-embedding-3-small"
    static let targetDim = 1536
    /// text-embedding-3-small rejects inputs over 8191 tokens with a 400.
    /// Whole-document embeds (vault files, link captures) are not chunked, so
    /// cap the input instead of failing the ingest. 16k characters stays under
    /// the token limit even for token-dense text (code, non-Latin scripts); a
    /// document vector is a coarse signal anyway — chunks carry the detail.
    static let defaultMaxInputCharacters = 16000

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let providerLabel: String
    private let maxInputCharacters: Int
    private let session: URLSession
    private let logger: Logger
    private let usageCallback: (@Sendable (UUID, Int64) async -> Void)?

    init(
        apiKey: String,
        baseURL: URL = OpenAIEmbeddingService.defaultBaseURL,
        model: String = OpenAIEmbeddingService.defaultModel,
        providerLabel: String = "openai",
        maxInputCharacters: Int = OpenAIEmbeddingService.defaultMaxInputCharacters,
        session: URLSession = .shared,
        logger: Logger = Logger(label: "lv.embedding.openai"),
        usageCallback: (@Sendable (UUID, Int64) async -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.providerLabel = providerLabel
        self.maxInputCharacters = max(1, maxInputCharacters)
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
        let input = text.count > maxInputCharacters ? String(text.prefix(maxInputCharacters)) : text
        let body = RequestBody(model: model, input: input, dimensions: Self.targetDim, encodingFormat: "float")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingProviderError.network(reason: "\(providerLabel): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.network(reason: "\(providerLabel): non-http response")
        }
        if let error = EmbeddingProviderError.fromHTTP(status: http.statusCode, body: data, providerLabel: providerLabel) {
            throw error
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
