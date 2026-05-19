import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat

/// HER-240c — narrow HTTP proxy that forwards Grok-shaped requests to a
/// tenant's Hermes container OpenAI-compatible gateway. The proxy
/// constructs the upstream payload, attaches the per-tenant
/// `API_SERVER_KEY` bearer, and decodes the synthesised response.
///
/// We deliberately don't pipe streams (SSE) through in this first cut:
/// every iOS surface that needs Grok in HER-240c (chat reply, x_search
/// answer, vision caption) consumes a single-shot synthesised string.
/// Streaming reuses the existing `RoutedLLMTransport` path and lands when
/// a Grok-streamed surface (live agent loop) needs it.
struct HermesGrokProxy: Sendable {
    enum Error: Swift.Error, Equatable {
        case nonZeroStatus(Int)
        case decodeFailed
        case missingAnswer
    }

    private let httpClient: HTTPClient
    private let logger: Logger
    private let timeoutSeconds: Int64

    init(httpClient: HTTPClient, logger: Logger, timeoutSeconds: Int64 = 60) {
        self.httpClient = httpClient
        self.logger = logger
        self.timeoutSeconds = timeoutSeconds
    }

    /// POST `/v1/chat/completions` on the container's gateway with the
    /// `grok-4.3` (or caller-specified) model selected. The container's
    /// xai-oauth credentials route it through xAI's Responses API.
    func chat(handle: HermesContainerHandle, request: GrokChatRequest) async throws -> GrokChatResponse {
        let model = request.model ?? "grok-4.3"
        let body = ChatCompletionsRequest(
            model: model,
            messages: request.messages.map { .init(role: $0.role, content: $0.content) },
            maxTokens: request.maxTokens,
        )
        let response: ChatCompletionsResponse = try await post(
            handle: handle,
            path: "/v1/chat/completions",
            body: body,
        )
        guard let first = response.choices.first?.message.content else {
            throw Error.missingAnswer
        }
        return GrokChatResponse(
            answer: first,
            model: response.model ?? model,
            usage: response.usage.map {
                GrokUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
            },
        )
    }

    /// POST `/v1/responses` with the `x_search` tool injected. Hermes
    /// routes this to xAI which returns the synthesised answer plus
    /// citation list directly.
    func xSearch(handle: HermesContainerHandle, request: GrokXSearchRequest) async throws -> GrokXSearchResponse {
        let body = ResponsesRequest(
            model: "grok-4.20-reasoning",
            input: request.query,
            tools: [.init(type: "x_search", xSearch: .init(
                allowedXHandles: request.allowedXHandles,
                excludedXHandles: request.excludedXHandles,
                fromDate: request.fromDate,
                toDate: request.toDate,
                enableImageUnderstanding: request.enableImageUnderstanding,
                enableVideoUnderstanding: request.enableVideoUnderstanding,
            ))],
        )
        let response: ResponsesAPIResponse = try await post(
            handle: handle,
            path: "/v1/responses",
            body: body,
        )
        return GrokXSearchResponse(
            answer: response.output ?? "",
            citations: (response.citations ?? []).map {
                GrokXSearchCitation(url: $0.url, title: $0.title, publishedAt: $0.publishedAt)
            },
            model: response.model ?? "grok-4.20-reasoning",
        )
    }

    /// Vision request — chat-completions with `image_url` content blocks.
    func vision(handle: HermesContainerHandle, request: GrokVisionRequest) async throws -> GrokVisionResponse {
        // Construct a single user message with the prompt + image URLs.
        var contentParts: [VisionContentPart] = [.init(type: "text", text: request.prompt, imageURL: nil)]
        for url in request.imageURLs {
            contentParts.append(.init(type: "image_url", text: nil, imageURL: .init(url: url)))
        }
        let body = VisionRequest(
            model: "grok-4.3",
            messages: [.init(role: "user", content: contentParts)],
        )
        let response: ChatCompletionsResponse = try await post(
            handle: handle,
            path: "/v1/chat/completions",
            body: body,
        )
        guard let answer = response.choices.first?.message.content else {
            throw Error.missingAnswer
        }
        return GrokVisionResponse(answer: answer, model: response.model ?? "grok-4.3")
    }

    // MARK: - Transport

    private func post<RequestBody: Encodable, Body: Decodable>(
        handle: HermesContainerHandle,
        path: String,
        body: RequestBody,
    ) async throws -> Body {
        var req = HTTPClientRequest(url: handle.baseURL + path)
        req.method = .POST
        req.headers.add(name: "Content-Type", value: "application/json")
        req.headers.add(name: "Authorization", value: "Bearer \(handle.apiServerKey)")
        let payload = try JSONEncoder.snakeCase.encode(body)
        req.body = .bytes(payload)

        let response = try await httpClient.execute(req, timeout: .seconds(timeoutSeconds))
        let bodyBytes = try await response.body.collect(upTo: 8 * 1024 * 1024)
        guard (200..<300).contains(Int(response.status.code)) else {
            logger.warning("hermes grok proxy non-2xx", metadata: [
                "status": "\(response.status.code)",
                "container": "\(handle.containerName)",
                "path": "\(path)",
            ])
            throw Error.nonZeroStatus(Int(response.status.code))
        }
        do {
            return try JSONDecoder.snakeCase.decode(Body.self, from: Data(buffer: bodyBytes))
        } catch {
            logger.error("hermes grok proxy decode failed: \(error)")
            throw Error.decodeFailed
        }
    }
}

// MARK: - Upstream payloads

/// OpenAI chat-completions request shape. Per-tenant Hermes accepts this.
private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let maxTokens: Int?
}

private struct VisionContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: ImageURL?
    struct ImageURL: Encodable {
        let url: String
    }
}

private struct VisionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [VisionContentPart]
    }
    let model: String
    let messages: [Message]
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
    }
    let model: String?
    let choices: [Choice]
    let usage: Usage?
}

private struct ResponsesRequest: Encodable {
    struct Tool: Encodable {
        let type: String
        let xSearch: XSearchParams
        enum CodingKeys: String, CodingKey { case type, xSearch = "x_search" }
    }
    struct XSearchParams: Encodable {
        let allowedXHandles: [String]?
        let excludedXHandles: [String]?
        let fromDate: String?
        let toDate: String?
        let enableImageUnderstanding: Bool?
        let enableVideoUnderstanding: Bool?
    }
    let model: String
    let input: String
    let tools: [Tool]
}

private struct ResponsesAPIResponse: Decodable {
    struct Citation: Decodable {
        let url: String
        let title: String?
        let publishedAt: Date?
    }
    let model: String?
    let output: String?
    let citations: [Citation]?
}

// MARK: - JSON helpers

private extension JSONEncoder {
    static var snakeCase: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}

private extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
