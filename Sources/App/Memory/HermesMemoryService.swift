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
    /// JSONSchema `items` for `type: "array"` properties. Hermes / OpenAI
    /// tool-calling models behave erratically with bare arrays, so any
    /// array property should declare its element type here.
    let items: ItemsSchema?

    init(
        type: String,
        description: String? = nil,
        additionalProperties: Bool? = nil,
        items: ItemsSchema? = nil
    ) {
        self.type = type
        self.description = description
        self.additionalProperties = additionalProperties
        self.items = items
    }
}

private struct ItemsSchema: Encodable, Sendable {
    let type: String
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
    /// HER-150: optional vault file ID the memory was derived from. The
    /// model is told to pass this whenever the upsert is grounded in a
    /// recently-read vault file so `GET /v1/memory/{id}/lineage` can
    /// reconstruct the trace later.
    let sourceVaultFileId: UUID?
}

private struct SessionSearchArgs: Decodable, Sendable {
    let query: String
    let limit: Int?
}

private struct TagExtractArgs: Decodable, Sendable {
    let tags: [String]
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
                Workflow — do BOTH steps before replying:
                  1. Call `memory_upsert` exactly once with the content provided.
                  2. Call `tag_extract` exactly once with 1–5 short topical tags
                     summarizing the memory's subject. Tags must be lowercase,
                     1–2 words each, no punctuation. Examples: "running",
                     "work-meeting", "swift", "ios-bug".
                After both tools return, reply with a one-sentence acknowledgement
                summarizing what was stored.
                """),
            .init(role: "user", content: content)
        ]
        let outcome = try await runAgent(
            tenantID: tenantID,
            profileUsername: profileUsername,
            messages: messages,
            allowedTools: [.memoryUpsert, .sessionSearch, .tagExtract]
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
        case memoryUpsert, sessionSearch, tagExtract
    }

    /// HER-151: cap + normalize Hermes-supplied tags. Lowercase + trim,
    /// drop empties, dedupe (preserves first-occurrence order), max 5.
    static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            let cleaned = value
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }
            if seen.insert(cleaned).inserted {
                out.append(cleaned)
                if out.count == 5 { break }
            }
        }
        return out
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
                    embedding: embedding,
                    sourceVaultFileID: args.sourceVaultFileId
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

        case "tag_extract":
            do {
                let args = try decoder.decode(TagExtractArgs.self, from: argsData)
                let normalized = Self.normalizeTags(args.tags)
                guard let target = outcome.memoriesUpserted.last else {
                    return Self.toolErrorJSON("tag_extract called before memory_upsert")
                }
                let memoryID = try target.requireID()
                let updated = try await memories.updateTags(
                    tenantID: tenantID,
                    id: memoryID,
                    tags: normalized
                )
                if updated {
                    target.tags = normalized.isEmpty ? nil : normalized
                }
                return Self.encodeJSON([
                    "status": "ok",
                    "tags_count": String(normalized.count)
                ])
            } catch {
                return Self.toolErrorJSON("tag_extract failed: \(error)")
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
                        ),
                        "source_vault_file_id": PropertySchema(
                            type: "string",
                            description: """
                                Optional UUID of the vault file this memory was derived from. \
                                Pass this when the memory is grounded in a specific note or \
                                document the user just captured or that you read via vault_read \
                                so the system can build a "Hermes learned X from your <date> note" \
                                lineage trace. Omit when the memory is volunteered by the user \
                                with no anchor file.
                                """
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
        case .tagExtract:
            return ToolDefinition(function: .init(
                name: "tag_extract",
                description: """
                    Attach 1–5 short topical tags to the most recently upserted memory. \
                    Tags MUST be lowercase, 1–2 words each, no punctuation. Used by the UI's \
                    filter list and the spaced-repetition picker, so prefer stable, reusable \
                    tags ("running", "swift", "work-meeting") over one-off labels.
                    """,
                parameters: ParameterSchema(
                    properties: [
                        "tags": PropertySchema(
                            type: "array",
                            description: "1–5 lowercase tag strings.",
                            items: ItemsSchema(type: "string")
                        )
                    ],
                    required: ["tags"]
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
