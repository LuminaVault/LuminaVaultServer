import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol HermesLLMService: Sendable {
    func chat(profileUsername: String, request: ChatRequest) async throws -> ChatResponse
}

/// Outbound request body for the Hermes OpenAI-compatible gateway.
private struct HermesUpstreamRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
    }
}

struct DefaultHermesLLMService: HermesLLMService {
    let baseURL: URL
    let session: URLSession
    let defaultModel: String
    let logger: Logger

    func chat(profileUsername: String, request: ChatRequest) async throws -> ChatResponse {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ASSUMPTION: upstream Hermes gateway routes per-profile traffic via this header.
        // If wrong, swap to `model: "<username>/<base>"` or `?profile=` here.
        urlReq.setValue(profileUsername, forHTTPHeaderField: "X-Hermes-Profile")

        let payload = HermesUpstreamRequest(
            model: request.model ?? defaultModel,
            messages: request.messages,
            temperature: request.temperature,
            stream: false
        )
        urlReq.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: urlReq)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(.badGateway, message: "hermes upstream returned no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("hermes upstream \(http.statusCode): \(preview)")
            throw HTTPError(.badGateway, message: "hermes upstream error (\(http.statusCode))")
        }

        let decoder = JSONDecoder()
        let raw: HermesUpstreamResponse
        do {
            raw = try decoder.decode(HermesUpstreamResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("hermes decode failed: \(error). body=\(preview)")
            throw HTTPError(.badGateway, message: "hermes upstream returned malformed body")
        }
        guard let assistant = raw.choices.first?.message else {
            throw HTTPError(.badGateway, message: "hermes upstream returned no choices")
        }
        return ChatResponse(id: raw.id, model: raw.model, message: assistant, raw: raw)
    }
}
