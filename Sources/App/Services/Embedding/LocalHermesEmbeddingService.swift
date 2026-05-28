import Foundation
import Logging

/// HER-134 — calls the per-tenant Hermes container at
/// `{container}:8642/v1/embeddings` (OpenAI-compatible shape). The
/// container ships the model itself; nothing about the request leaves the
/// docker network, hence "privacy-first" path. Resolution is read-only:
/// if no container exists yet for the tenant, throws
/// `.permanent(.endpointMissing)` so the fallback chain advances rather
/// than spawning a container on the embed hot path.
final class LocalHermesEmbeddingService: EmbeddingService {
    static let targetDim = 1536
    static let defaultModel = "nomic-embed-text-v1.5"

    /// Read-only handle resolver. Returning `nil` means "no container for
    /// this tenant yet" and triggers an endpoint-missing fall-through.
    typealias HandleResolver = @Sendable (UUID) async throws -> HermesContainerHandle?

    private let resolveHandle: HandleResolver
    private let model: String
    private let session: URLSession
    private let logger: Logger

    init(
        resolveHandle: @escaping HandleResolver,
        model: String = LocalHermesEmbeddingService.defaultModel,
        session: URLSession = .shared,
        logger: Logger = Logger(label: "lv.embedding.hermesLocal"),
    ) {
        self.resolveHandle = resolveHandle
        self.model = model
        self.session = session
        self.logger = logger
    }

    func embed(_ text: String, tenantID: UUID) async throws -> [Float] {
        let handle: HermesContainerHandle?
        do {
            handle = try await resolveHandle(tenantID)
        } catch {
            throw EmbeddingProviderError.network(reason: "hermesLocal handle: \(error.localizedDescription)")
        }
        guard let handle else {
            throw EmbeddingProviderError.permanent(reason: .endpointMissing)
        }
        guard let url = URL(string: "\(handle.baseURL)/v1/embeddings") else {
            throw EmbeddingProviderError.permanent(reason: .endpointMissing)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !handle.apiServerKey.isEmpty {
            request.setValue("Bearer \(handle.apiServerKey)", forHTTPHeaderField: "Authorization")
        }
        let body = RequestBody(model: model, input: text)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingProviderError.network(reason: "hermesLocal: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.network(reason: "hermesLocal: non-http response")
        }
        switch http.statusCode {
        case 200 ..< 300: break
        case 404:
            throw EmbeddingProviderError.permanent(reason: .endpointMissing)
        case 401, 403:
            throw EmbeddingProviderError.permanent(reason: .authRejected)
        case 408, 429, 500 ..< 600:
            throw EmbeddingProviderError.transient(reason: "hermesLocal http \(http.statusCode)")
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
        let vec = first.embedding
        if vec.count == Self.targetDim {
            return vec
        }
        if vec.count < Self.targetDim {
            var padded = vec
            padded.append(contentsOf: [Float](repeating: 0, count: Self.targetDim - vec.count))
            return padded
        }
        throw EmbeddingProviderError.dimMismatch(expected: Self.targetDim, got: vec.count)
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: String
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable { let embedding: [Float] }
        let data: [Item]
    }
}
