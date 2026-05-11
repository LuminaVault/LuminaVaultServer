import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Public surface

struct MemoGenerationResult {
    /// Final markdown body returned to the caller (with frontmatter prepended).
    let memo: String
    /// Vault path (relative to `<rawRoot>`) when saved; nil for dry runs.
    let path: String?
    /// IDs of memories Hermes consulted via `session_search` calls.
    let sourceMemoryIDs: [UUID]
    /// Hermes' last assistant turn — the body without frontmatter.
    let summary: String
}

// MARK: - Internal chat-completion shapes (same wire format as HermesMemoryService)

private struct ToolFunctionCall: Codable {
    let name: String
    let arguments: String
}

private struct ToolCall: Codable {
    let id: String
    let type: String
    let function: ToolFunctionCall
}

private struct AgentMessage: Codable {
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
        self.role = role; self.content = content
        self.toolCalls = toolCalls; self.toolCallId = toolCallId; self.name = name
    }
}

private struct ToolDefinition: Encodable {
    let type = "function"
    let function: Function
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: ParameterSchema
    }
}

private struct ParameterSchema: Encodable {
    let type = "object"
    let properties: [String: PropertySchema]
    let required: [String]
}

private struct PropertySchema: Encodable {
    let type: String
    let description: String?
    init(type: String, description: String? = nil) {
        self.type = type; self.description = description
    }
}

private struct ChatRequestBody: Encodable {
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

private struct ChatResponseChoice: Decodable {
    let message: AgentMessage
    let finishReason: String?
    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct ChatResponseBody: Decodable {
    let id: String
    let model: String
    let choices: [ChatResponseChoice]
}

private struct SessionSearchArgs: Decodable {
    let query: String
    let limit: Int?
}

// MARK: - Service

/// Drives Hermes through an agent loop with **read-only** memory tools to
/// produce a synthesizing markdown memo. Distinct from
/// `HermesMemoryService.upsert` (which writes memories IN); this writes
/// memos OUT to the vault, without ever calling `memory_upsert`.
///
/// On `save=true`, the resulting memo lands at
/// `<rawRoot>/memos/<YYYY-MM-DD>/<slug>.md` and gets a `vault_files` row
/// so it shows up in the vault browser like any other note.
actor MemoGeneratorService {
    let transport: any HermesChatTransport
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let vaultPaths: VaultPathService
    let fluent: Fluent
    let defaultModel: String
    let logger: Logger
    let maxToolIterations: Int
    let maxMemoBytes: Int

    init(
        transport: any HermesChatTransport,
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        vaultPaths: VaultPathService,
        fluent: Fluent,
        defaultModel: String,
        logger: Logger,
        maxToolIterations: Int = 6,
        maxMemoBytes: Int = 32 * 1024,
    ) {
        self.transport = transport
        self.memories = memories
        self.embeddings = embeddings
        self.vaultPaths = vaultPaths
        self.fluent = fluent
        self.defaultModel = defaultModel
        self.logger = logger
        self.maxToolIterations = maxToolIterations
        self.maxMemoBytes = maxMemoBytes
    }

    func generate(
        tenantID: UUID,
        profileUsername: String,
        topic: String,
        hint: String?,
        save: Bool,
    ) async throws -> MemoGenerationResult {
        guard !topic.isEmpty, topic.count <= 256 else {
            throw HTTPError(.badRequest, message: "topic empty or too long")
        }

        let outcome = try await runAgent(
            tenantID: tenantID,
            profileUsername: profileUsername,
            topic: topic,
            hint: hint,
        )

        let bodyBytes = outcome.summary.utf8.count
        guard bodyBytes <= maxMemoBytes else {
            throw HTTPError(.contentTooLarge, message: "memo exceeds \(maxMemoBytes) bytes")
        }

        let memoMarkdown = renderMarkdown(
            topic: topic,
            sourceIDs: outcome.consultedMemoryIDs,
            body: outcome.summary,
        )

        var savedPath: String? = nil
        if save {
            savedPath = try await persist(
                tenantID: tenantID,
                topic: topic,
                memo: memoMarkdown,
            )
        }

        return MemoGenerationResult(
            memo: memoMarkdown,
            path: savedPath,
            sourceMemoryIDs: outcome.consultedMemoryIDs,
            summary: outcome.summary,
        )
    }

    // MARK: - Agent loop (read-only)

    private struct LoopOutcome {
        var summary: String = ""
        var consultedMemoryIDs: [UUID] = []
    }

    private func runAgent(
        tenantID: UUID,
        profileUsername: String,
        topic: String,
        hint: String?,
    ) async throws -> LoopOutcome {
        let systemPrompt = """
        You are Hermes writing a synthesis memo for the user. Your job:
        1. Search their memories for the supplied topic using `session_search`.
        2. Refine your search 1-2 more times if the first batch is sparse.
        3. Write a structured markdown memo with these sections:
           ## Summary
           ## Key Points
           ## Connections
           ## Open Questions
        4. Cite sources inline with `[[memory:<uuid>]]` for any claim that
           comes from a stored memory. Do NOT invent quotes or facts.
        5. Match the user's voice from their existing notes — do not
           default to corporate tone.

        If there are no relevant memories, write a short "Hermes hasn't
        seen anything about <topic> yet" memo and stop.
        \(hint.map { "User hint: \($0)" } ?? "")
        """

        var conversation: [AgentMessage] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: "Topic: \(topic)"),
        ]
        let tools = [Self.sessionSearchTool()]
        var outcome = LoopOutcome()
        var seen = Set<UUID>()

        for _ in 0 ..< maxToolIterations {
            let body = ChatRequestBody(
                model: defaultModel,
                messages: conversation,
                tools: tools,
                toolChoice: "auto",
                temperature: 0.3,
                stream: false,
            )
            let payload = try JSONEncoder().encode(body)
            let raw = try await transport.chatCompletions(payload: payload, profileUsername: profileUsername)
            let response = try JSONDecoder().decode(ChatResponseBody.self, from: raw)
            guard let choice = response.choices.first else {
                throw HTTPError(.badGateway, message: "hermes returned no choices")
            }
            let assistant = choice.message
            conversation.append(assistant)

            if let calls = assistant.toolCalls, !calls.isEmpty {
                for call in calls {
                    let result = try await dispatch(
                        tenantID: tenantID,
                        toolCall: call,
                        seen: &seen,
                        outcome: &outcome,
                    )
                    conversation.append(.init(
                        role: "tool",
                        content: result,
                        toolCallId: call.id,
                        name: call.function.name,
                    ))
                }
                continue
            }

            outcome.summary = assistant.content ?? ""
            return outcome
        }
        logger.warning("memo agent loop hit max iterations \(maxToolIterations)")
        throw HTTPError(.badGateway, message: "memo generator did not converge")
    }

    private func dispatch(
        tenantID: UUID,
        toolCall: ToolCall,
        seen: inout Set<UUID>,
        outcome: inout LoopOutcome,
    ) async throws -> String {
        guard toolCall.function.name == "session_search" else {
            return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
        }
        guard let argsData = toolCall.function.arguments.data(using: .utf8) else {
            return Self.toolErrorJSON("invalid arguments encoding")
        }
        do {
            let args = try JSONDecoder().decode(SessionSearchArgs.self, from: argsData)
            let queryEmbedding = try await embeddings.embed(args.query)
            let hits = try await memories.semanticSearch(
                tenantID: tenantID,
                queryEmbedding: queryEmbedding,
                limit: max(1, min(args.limit ?? 5, 20)),
            )
            for hit in hits where !seen.contains(hit.id) {
                seen.insert(hit.id)
                outcome.consultedMemoryIDs.append(hit.id)
            }
            let serializable = hits.map { hit -> [String: String] in
                ["id": hit.id.uuidString, "content": hit.content, "distance": String(hit.distance)]
            }
            return Self.encodeJSON(["status": "ok", "results": serializable])
        } catch {
            return Self.toolErrorJSON("session_search failed: \(error)")
        }
    }

    // MARK: - Markdown render + persist

    private func renderMarkdown(topic: String, sourceIDs: [UUID], body: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var frontmatter = "---\n"
        frontmatter += "topic: \"\(topic.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
        frontmatter += "generated_at: \(formatter.string(from: Date()))\n"
        frontmatter += "hermes_model: \(defaultModel)\n"
        if !sourceIDs.isEmpty {
            frontmatter += "source_memory_ids:\n"
            for id in sourceIDs {
                frontmatter += "  - \(id.uuidString)\n"
            }
        }
        frontmatter += "---\n\n"
        return frontmatter + body
    }

    private func persist(tenantID: UUID, topic: String, memo: String) async throws -> String {
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let dateStamp = Self.dateStamp()
        let slug = Self.slug(topic)
        let relativeDir = "memos/\(dateStamp)"
        let fileName = "\(slug).md"
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let dir = rawRoot.appendingPathComponent(relativeDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var target = dir.appendingPathComponent(fileName)
        var finalRelative = "\(relativeDir)/\(fileName)"
        // Don't clobber: append `-<8hex>` if a memo on this topic already exists today.
        if FileManager.default.fileExists(atPath: target.path) {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let altName = "\(slug)-\(suffix).md"
            target = dir.appendingPathComponent(altName)
            finalRelative = "\(relativeDir)/\(altName)"
        }

        let data = Data(memo.utf8)
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: target)

        // VaultFile row so the memo shows in the vault browser like any other note.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let row = VaultFile(
            tenantID: tenantID,
            spaceID: nil,
            path: finalRelative,
            contentType: "text/markdown",
            sizeBytes: Int64(data.count),
            sha256: digest,
        )
        try await row.save(on: fluent.db())

        logger.info("memo saved tenant=\(tenantID) path=\(finalRelative) size=\(data.count)")
        return finalRelative
    }

    // MARK: - Tool schema

    private static func sessionSearchTool() -> ToolDefinition {
        ToolDefinition(function: .init(
            name: "session_search",
            description: "Semantic-search the user's memories. Read-only. Returns up to `limit` memories.",
            parameters: ParameterSchema(
                properties: [
                    "query": PropertySchema(type: "string", description: "Natural-language search query."),
                    "limit": PropertySchema(type: "integer", description: "Maximum memories (1-20, default 5)."),
                ],
                required: ["query"],
            ),
        ))
    }

    // MARK: - Helpers

    /// Slug for filename: lowercase, alphanum + hyphen, ≤64 chars.
    static func slug(_ topic: String) -> String {
        let lower = topic.lowercased()
        var s = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                s.append(ch)
            } else if ch == " " || ch == "-" || ch == "_" {
                if !s.isEmpty, s.last != "-" {
                    s.append("-")
                }
            }
        }
        while s.last == "-" {
            s.removeLast()
        }
        if s.isEmpty { s = "memo" }
        if s.count > 64 { s = String(s.prefix(64)) }
        return s
    }

    static func dateStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"status\":\"error\"}" }
        return s
    }

    private static func toolErrorJSON(_ reason: String) -> String {
        encodeJSON(["status": "error", "reason": reason])
    }
}
