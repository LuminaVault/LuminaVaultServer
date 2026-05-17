import Crypto
import FluentKit
import Foundation
import Hummingbird
import Logging
import SQLKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - DTOs

struct InternalKBCompileWrittenFile: Codable {
    let path: String
    let size: Int
    let contentType: String
    let sha256: String
}

struct InternalKBCompileMemoryRef: Codable {
    let id: UUID
    let content: String
}

struct InternalKBCompileResult {
    let writtenFiles: [InternalKBCompileWrittenFile]
    let memories: [InternalKBCompileMemoryRef]
    let summary: String
}

enum KBCompileError: Error {
    case fileTooLarge(path: String, limit: Int)
    case noFiles
}

// MARK: - Service

/// kb-compile = "ingest a batch of new vault files + run Hermes' learning
/// loop over them". Writes each file into `<rawRoot>/<path>` (same surface
/// as `VaultController.upload`), then sends the compiled corpus to the
/// per-user Hermes profile through `HermesMemoryService.runAgent`-style
/// chat with `memory_upsert` exposed. The model decides which memories to
/// persist; the service reports back the ones that landed.
actor KBCompileService {
    let vaultPaths: VaultPathService
    let transport: any HermesChatTransport
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let defaultModel: String
    let logger: Logger
    let maxFileSize: Int
    let maxBatchBytes: Int
    let maxToolIterations: Int

    init(
        vaultPaths: VaultPathService,
        transport: any HermesChatTransport,
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        defaultModel: String,
        logger: Logger,
        maxFileSize: Int = 10 * 1024 * 1024,
        maxBatchBytes: Int = 32 * 1024 * 1024,
        maxToolIterations: Int = 12,
    ) {
        self.vaultPaths = vaultPaths
        self.transport = transport
        self.memories = memories
        self.embeddings = embeddings
        self.defaultModel = defaultModel
        self.logger = logger
        self.maxFileSize = maxFileSize
        self.maxBatchBytes = maxBatchBytes
        self.maxToolIterations = maxToolIterations
    }

    func compileExistingVaultFiles(
        tenantID: UUID,
        profileUsername: String,
        rows: [VaultFile],
        hint: String?,
    ) async throws -> InternalKBCompileResult {
        guard !rows.isEmpty else { throw KBCompileError.noFiles }

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        var writtenFiles: [InternalKBCompileWrittenFile] = []
        var compiledTextBlocks: [(path: String, content: String, contentType: String)] = []
        var totalBytes = 0
        var rowIDs: [UUID] = []

        for row in rows {
            let rowID = try row.requireID()
            let safeRelative = try VaultController.sanitizePath(row.path)
            let target = try VaultController.resolveInside(rawRoot: rawRoot, relative: safeRelative)
            let payload = try Data(contentsOf: target)
            guard payload.count <= maxFileSize else {
                throw KBCompileError.fileTooLarge(path: safeRelative, limit: maxFileSize)
            }
            totalBytes += payload.count
            guard totalBytes <= maxBatchBytes else {
                throw HTTPError(.contentTooLarge, message: "batch exceeds \(maxBatchBytes) bytes")
            }

            writtenFiles.append(InternalKBCompileWrittenFile(
                path: safeRelative,
                size: payload.count,
                contentType: row.contentType,
                sha256: row.sha256,
            ))
            rowIDs.append(rowID)

            if Self.isTextLike(contentType: row.contentType),
               let text = String(data: payload, encoding: .utf8)
            {
                compiledTextBlocks.append((safeRelative, text, row.contentType))
            }
        }

        logger.info("kb-compile processing \(rows.count) existing files (\(totalBytes) bytes) for tenant \(tenantID)")
        let summary = try await runCompileLoop(
            tenantID: tenantID,
            profileUsername: profileUsername,
            blocks: compiledTextBlocks,
            hint: hint,
        )
        try await markVaultFilesProcessed(ids: rowIDs, at: Date())
        return InternalKBCompileResult(
            writtenFiles: writtenFiles,
            memories: summary.memories,
            summary: summary.text,
        )
    }

    // MARK: - Internals

    private struct CompileSummary {
        let text: String
        let memories: [InternalKBCompileMemoryRef]
    }

    private struct ChatPayload: Encodable {
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
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
            self.name = name
        }
    }

    private struct ToolCall: Codable {
        let id: String
        let type: String
        let function: FunctionCall
    }

    private struct FunctionCall: Codable {
        let name: String
        let arguments: String
    }

    private struct ToolDefinition: Encodable {
        let type = "function"
        let function: FunctionInfo
        struct FunctionInfo: Encodable {
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
    }

    private struct ChatResponseBody: Decodable {
        struct Choice: Decodable {
            let message: AgentMessage
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        let id: String
        let model: String
        let choices: [Choice]
    }

    private struct MemoryUpsertArgs: Decodable {
        let content: String
    }

    private func runCompileLoop(
        tenantID: UUID,
        profileUsername: String,
        blocks: [(path: String, content: String, contentType: String)],
        hint: String?,
    ) async throws -> CompileSummary {
        let systemPrompt = """
        You are Hermes' kb-compile agent. The user just dropped a batch of \
        files into their vault. Your job is to (a) extract the durable, \
        high-signal memories from those files (preferences, decisions, \
        facts, TODOs, recurring patterns) and (b) call the `memory_upsert` \
        tool once for each distinct memory you want to persist. After all \
        useful memories are saved, reply with a short summary covering: \
        how many memories you stored, which themes you saw, anything you \
        deliberately skipped. Never invent — only extract what's in the \
        files.
        \(hint.map { "User hint: \($0)" } ?? "")
        """

        let bundled: String = if blocks.isEmpty {
            "(No text-shaped files in this batch — only binary assets were written.)"
        } else {
            blocks.map { block in
                "----- FILE: \(block.path) (\(block.contentType)) -----\n\(block.content)"
            }.joined(separator: "\n\n")
        }

        var conversation: [AgentMessage] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: bundled),
        ]
        let tools = [Self.memoryUpsertTool()]
        var collectedMemories: [InternalKBCompileMemoryRef] = []

        for _ in 0 ..< maxToolIterations {
            let body = ChatPayload(
                model: defaultModel,
                messages: conversation,
                tools: tools,
                toolChoice: "auto",
                temperature: 0.2,
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
                        memories: &collectedMemories,
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

            return CompileSummary(text: assistant.content ?? "", memories: collectedMemories)
        }

        logger.warning("kb-compile loop hit max iterations \(maxToolIterations)")
        throw HTTPError(.badGateway, message: "kb-compile did not converge")
    }

    private func dispatch(
        tenantID: UUID,
        toolCall: ToolCall,
        memories: inout [InternalKBCompileMemoryRef],
    ) async throws -> String {
        guard toolCall.function.name == "memory_upsert" else {
            return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
        }
        guard let argsData = toolCall.function.arguments.data(using: .utf8) else {
            return Self.toolErrorJSON("invalid arguments encoding")
        }
        do {
            let args = try JSONDecoder().decode(MemoryUpsertArgs.self, from: argsData)
            let embedding = try await embeddings.embed(args.content)
            let saved = try await self.memories.create(
                tenantID: tenantID,
                content: args.content,
                embedding: embedding,
            )
            let id = try saved.requireID()
            memories.append(InternalKBCompileMemoryRef(id: id, content: saved.content))
            return Self.encodeJSON(["status": "ok", "id": id.uuidString])
        } catch {
            return Self.toolErrorJSON("memory_upsert failed: \(error)")
        }
    }

    // MARK: - Tool schema

    private static func memoryUpsertTool() -> ToolDefinition {
        ToolDefinition(function: .init(
            name: "memory_upsert",
            description: """
            Persist a single distilled memory from the kb-compile batch. The \
            content is embedded server-side and stored under the user's tenant.
            """,
            parameters: ParameterSchema(
                properties: [
                    "content": PropertySchema(
                        type: "string",
                        description: "The memory text to persist verbatim. Should be self-contained.",
                    ),
                ],
                required: ["content"],
            ),
        ))
    }

    // MARK: - Helpers

    private static func isTextLike(contentType: String) -> Bool {
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? contentType.lowercased()
        return mime.hasPrefix("text/")
    }

    private func markVaultFilesProcessed(ids: [UUID], at date: Date) async throws {
        guard let sql = memories.fluent.db() as? any SQLDatabase, !ids.isEmpty else { return }
        let literal = "ARRAY[" + ids.map { "'\($0.uuidString)'" }.joined(separator: ",") + "]::uuid[]"
        try await sql.raw("""
        UPDATE vault_files
        SET processed_at = \(bind: date),
            updated_at = updated_at
        WHERE id = ANY(\(unsafeRaw: literal))
        """).run()
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8)
        else {
            return "{\"status\":\"error\"}"
        }
        return s
    }

    private static func toolErrorJSON(_ reason: String) -> String {
        encodeJSON(["status": "error", "reason": reason])
    }
}
