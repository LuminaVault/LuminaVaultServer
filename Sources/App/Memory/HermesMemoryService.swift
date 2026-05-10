import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public surface

struct MemoryUpsertResult: Sendable {
    let memory: Memory
    /// Hermes' final assistant message (acknowledgement / synthesis).
    let summary: String
}

struct MemorySearchAnswer: Sendable {
    let hits: [MemorySearchResult]
    /// Hermes' synthesized answer over the retrieved hits.
    let summary: String
}

/// Abstracts the HTTP call to `<hermes>/v1/chat/completions` so tests can
/// drive the agent loop without a live container.
protocol HermesChatTransport: Sendable {
    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data
}

struct URLSessionHermesChatTransport: HermesChatTransport {
    let baseURL: URL
    let session: URLSession
    let logger: Logger

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(profileUsername, forHTTPHeaderField: "X-Hermes-Profile")
        req.httpBody = payload
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("hermes upstream chat failed: \(preview)")
            throw HTTPError(.badGateway, message: "hermes upstream error")
        }
        return data
    }
}

// MARK: - Internal chat-completion types (tool-calling extension)

private struct ToolFunctionCall: Codable, Sendable {
    let name: String
    let arguments: String
}

private struct ToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: ToolFunctionCall
}

private struct AgentMessage: Codable, Sendable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]?
    let toolCallId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }
}

private struct ToolDefinition: Encodable, Sendable {
    let type = "function"
    let function: Function

    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: ParameterSchema
    }
}

private struct ParameterSchema: Encodable, Sendable {
    let type = "object"
    let properties: [String: PropertySchema]
    let required: [String]
}

private struct PropertySchema: Encodable, Sendable {
    let type: String
    let description: String?
    let additionalProperties: Bool?

    init(type: String, description: String? = nil, additionalProperties: Bool? = nil) {
        self.type = type
        self.description = description
        self.additionalProperties = additionalProperties
    }
}

private struct ChatRequestBody: Encodable, Sendable {
    let model: String
    let messages: [AgentMessage]
    let tools: [ToolDefinition]
    let toolChoice: String
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature, stream
        case toolChoice = "tool_choice"
    }
}

private struct ChatResponseChoice: Decodable, Sendable {
    let index: Int?
    let message: AgentMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }
}

private struct ChatResponseBody: Decodable, Sendable {
    let id: String
    let model: String
    let choices: [ChatResponseChoice]
}

// MARK: - Tool argument types

private struct MemoryUpsertArgs: Decodable, Sendable {
    let content: String
}

private struct SessionSearchArgs: Decodable, Sendable {
    let query: String
    let limit: Int?
}

// MARK: - Service

/// Bridges chat traffic to the per-tenant memory store via Hermes' tool-calling
/// loop. Two public entry points:
///
/// - `upsert` instructs Hermes to call `memory_upsert(content)`. The handler
///   embeds + persists the memory in `MemoryRepository`. Hermes loops back
///   with an acknowledgement that becomes `MemoryUpsertResult.summary`.
///
/// - `search` instructs Hermes to call `session_search(query, limit?)`. The
///   handler runs a pgvector ANN query against the user's tenant slice.
///   Hermes summarizes the hits — useful when you want a synthesized
///   answer over scattered notes rather than raw rows.
///
/// Multi-iteration loop guarded by `maxToolIterations` so a misbehaving model
/// can't ping-pong tool calls forever.
actor HermesMemoryService {
    let transport: any HermesChatTransport
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let defaultModel: String
    let logger: Logger
    let maxToolIterations: Int

    init(
        transport: any HermesChatTransport,
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        defaultModel: String,
        logger: Logger,
        maxToolIterations: Int = 5
    ) {
        self.transport = transport
        self.memories = memories
        self.embeddings = embeddings
        self.defaultModel = defaultModel
        self.logger = logger
        self.maxToolIterations = maxToolIterations
    }

    func upsert(
        tenantID: UUID,
        profileUsername: String,
        content: String,
        metadata: [String: String]? = nil
    ) async throws -> MemoryUpsertResult {
        let messages: [AgentMessage] = [
            .init(role: "system", content: """
                You are Hermes, a per-user memory agent. The user wants to record a new memory.
                Call the `memory_upsert` tool exactly once with the content provided. After the
                tool returns, reply with a one-sentence acknowledgement summarizing what was stored.
                """),
            .init(role: "user", content: content)
        ]
        let outcome = try await runAgent(
            tenantID: tenantID,
            profileUsername: profileUsername,
            messages: messages,
            allowedTools: [.memoryUpsert, .sessionSearch]
        )
        guard let saved = outcome.memoriesUpserted.first else {
            throw HTTPError(.badGateway, message: "hermes did not call memory_upsert")
        }
        return MemoryUpsertResult(memory: saved, summary: outcome.summary)
    }

    func search(
        tenantID: UUID,
        profileUsername: String,
        query: String,
        limit: Int = 5
    ) async throws -> MemorySearchAnswer {
        let messages: [AgentMessage] = [
            .init(role: "system", content: """
                You are Hermes, a per-user memory agent. The user is asking you to recall.
                Call the `session_search` tool with the user's query and a sensible `limit`
                (default \(limit)). After the tool returns, synthesize a concise answer
                that cites the relevant memories you saw. If the search returns nothing,
                say so plainly.
                """),
            .init(role: "user", content: query)
        ]
        let outcome = try await runAgent(
            tenantID: tenantID,
            profileUsername: profileUsername,
            messages: messages,
            allowedTools: [.sessionSearch]
        )
        return MemorySearchAnswer(hits: outcome.searchHits, summary: outcome.summary)
    }

    // MARK: - Agent loop

    private struct AgentOutcome {
        var summary: String = ""
        var memoriesUpserted: [Memory] = []
        var searchHits: [MemorySearchResult] = []
    }

    private enum AvailableTool: CaseIterable {
        case memoryUpsert, sessionSearch
    }

    private func runAgent(
        tenantID: UUID,
        profileUsername: String,
        messages initial: [AgentMessage],
        allowedTools: [AvailableTool]
    ) async throws -> AgentOutcome {
        var conversation = initial
        var outcome = AgentOutcome()

        for _ in 0..<maxToolIterations {
            let body = ChatRequestBody(
                model: defaultModel,
                messages: conversation,
                tools: allowedTools.map { Self.definition(for: $0) },
                toolChoice: "auto",
                temperature: 0.2,
                stream: false
            )
            let payload = try JSONEncoder().encode(body)
            let raw = try await transport.chatCompletions(payload: payload, profileUsername: profileUsername)
            let response = try JSONDecoder().decode(ChatResponseBody.self, from: raw)
            guard let choice = response.choices.first else {
                throw HTTPError(.badGateway, message: "hermes returned no choices")
            }

            let assistant = choice.message
            conversation.append(assistant)

            // Plain assistant reply — agent is done.
            if let calls = assistant.toolCalls, !calls.isEmpty {
                for call in calls {
                    let result = try await dispatch(
                        tenantID: tenantID,
                        toolCall: call,
                        outcome: &outcome
                    )
                    conversation.append(.init(
                        role: "tool",
                        content: result,
                        toolCallId: call.id,
                        name: call.function.name
                    ))
                }
                continue
            }

            outcome.summary = assistant.content ?? ""
            return outcome
        }
        logger.warning("hermes agent loop hit max iterations (\(maxToolIterations))")
        throw HTTPError(.badGateway, message: "hermes agent did not converge")
    }

    private func dispatch(
        tenantID: UUID,
        toolCall: ToolCall,
        outcome: inout AgentOutcome
    ) async throws -> String {
        guard let argsData = toolCall.function.arguments.data(using: .utf8) else {
            return Self.toolErrorJSON("invalid arguments encoding")
        }
        let decoder = JSONDecoder()
        switch toolCall.function.name {
        case "memory_upsert":
            do {
                let args = try decoder.decode(MemoryUpsertArgs.self, from: argsData)
                let embedding = try await embeddings.embed(args.content)
                let saved = try await memories.create(
                    tenantID: tenantID,
                    content: args.content,
                    embedding: embedding
                )
                outcome.memoriesUpserted.append(saved)
                let payload: [String: String] = [
                    "status": "ok",
                    "id": (try? saved.requireID().uuidString) ?? ""
                ]
                return Self.encodeJSON(payload)
            } catch {
                return Self.toolErrorJSON("memory_upsert failed: \(error)")
            }

        case "session_search":
            do {
                let args = try decoder.decode(SessionSearchArgs.self, from: argsData)
                let embedding = try await embeddings.embed(args.query)
                let hits = try await memories.semanticSearch(
                    tenantID: tenantID,
                    queryEmbedding: embedding,
                    limit: max(1, min(args.limit ?? 5, 20))
                )
                outcome.searchHits = hits
                let serializable = hits.map { hit -> [String: String] in
                    [
                        "id": hit.id.uuidString,
                        "content": hit.content,
                        "distance": String(hit.distance)
                    ]
                }
                return Self.encodeJSON(["status": "ok", "results": serializable])
            } catch {
                return Self.toolErrorJSON("session_search failed: \(error)")
            }

        default:
            return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
        }
    }

    // MARK: - Tool schemas

    private static func definition(for tool: AvailableTool) -> ToolDefinition {
        switch tool {
        case .memoryUpsert:
            return ToolDefinition(function: .init(
                name: "memory_upsert",
                description: """
                    Persist a memory for the current user's tenant. The memory content is embedded \
                    server-side and stored in the `memories` table with the user's tenant_id. \
                    Call this when the user wants to remember, save, or note something.
                    """,
                parameters: ParameterSchema(
                    properties: [
                        "content": PropertySchema(
                            type: "string",
                            description: "The memory text to persist verbatim."
                        )
                    ],
                    required: ["content"]
                )
            ))
        case .sessionSearch:
            return ToolDefinition(function: .init(
                name: "session_search",
                description: """
                    Semantic-search the current user's memories via pgvector cosine similarity. \
                    Returns up to `limit` memories ordered by relevance, scoped strictly to the \
                    authenticated tenant.
                    """,
                parameters: ParameterSchema(
                    properties: [
                        "query": PropertySchema(
                            type: "string",
                            description: "The natural-language search query."
                        ),
                        "limit": PropertySchema(
                            type: "integer",
                            description: "Maximum number of memories to return (1-20, default 5)."
                        )
                    ],
                    required: ["query"]
                )
            ))
        }
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8)
        else {
            return "{\"status\":\"error\",\"reason\":\"could not encode tool result\"}"
        }
        return s
    }

    private static func toolErrorJSON(_ reason: String) -> String {
        encodeJSON(["status": "error", "reason": reason])
    }
}
