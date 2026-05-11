import Crypto
import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - DTOs

struct KBCompileFile: Codable {
    let path: String
    let contentType: String
    /// Plain text payload — use for markdown / .txt. Mutually exclusive with `base64`.
    let text: String?
    /// Base64-encoded bytes — use for images and other binary. Mutually exclusive with `text`.
    let base64: String?
}

struct KBCompileWrittenFile: Codable {
    let path: String
    let size: Int
    let contentType: String
    let sha256: String
}

struct KBCompileMemoryRef: Codable {
    let id: UUID
    let content: String
}

struct KBCompileResult {
    let writtenFiles: [KBCompileWrittenFile]
    let memories: [KBCompileMemoryRef]
    let summary: String
}

enum KBCompileError: Error {
    case missingPayload
    case bothPayloadsSet
    case invalidBase64
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

    func compile(
        tenantID: UUID,
        profileUsername: String,
        files: [KBCompileFile],
        hint: String?,
    ) async throws -> KBCompileResult {
        guard !files.isEmpty else { throw KBCompileError.noFiles }

        // 1. Write every file to the per-tenant raw vault.
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let rawRootPrefix = rawRoot.standardizedFileURL.path + "/"

        var writtenFiles: [KBCompileWrittenFile] = []
        var totalBytes = 0
        var compiledTextBlocks: [(path: String, content: String, contentType: String)] = []

        for file in files {
            let safeRelative = try VaultController.sanitizePath(file.path)
            try VaultController.validateContentType(
                file.contentType,
                againstExtension: (safeRelative as NSString).pathExtension.lowercased(),
            )
            let payload = try Self.decodePayload(file)
            guard payload.count <= maxFileSize else {
                throw KBCompileError.fileTooLarge(path: safeRelative, limit: maxFileSize)
            }
            totalBytes += payload.count
            guard totalBytes <= maxBatchBytes else {
                throw HTTPError(.contentTooLarge, message: "batch exceeds \(maxBatchBytes) bytes")
            }

            let target = rawRoot.appendingPathComponent(safeRelative)
            guard target.standardizedFileURL.path.hasPrefix(rawRootPrefix) else {
                throw HTTPError(.badRequest, message: "resolved path escapes vault root: \(safeRelative)")
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let tmp = target.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
            try payload.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tmp, to: target)

            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            writtenFiles.append(KBCompileWrittenFile(
                path: safeRelative,
                size: payload.count,
                contentType: file.contentType,
                sha256: digest,
            ))

            // Only feed text-shaped files into the chat. Images go to disk
            // but Hermes can't reason about pixel bytes via this surface.
            if Self.isTextLike(contentType: file.contentType), let text = file.text {
                compiledTextBlocks.append((safeRelative, text, file.contentType))
            }
        }

        logger.info("kb-compile wrote \(writtenFiles.count) files (\(totalBytes) bytes) for tenant \(tenantID)")

        // 2. Drive Hermes through the agent loop.
        let summary = try await runCompileLoop(
            tenantID: tenantID,
            profileUsername: profileUsername,
            blocks: compiledTextBlocks,
            hint: hint,
        )

        // 3. Reload memories created during the loop. We can't trivially
        // distinguish new from existing without per-call tracking; the loop
        // keeps a list itself.
        return KBCompileResult(
            writtenFiles: writtenFiles,
            memories: summary.memories,
            summary: summary.text,
        )
    }

    // MARK: - Internals

    private struct CompileSummary {
        let text: String
        let memories: [KBCompileMemoryRef]
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
        var collectedMemories: [KBCompileMemoryRef] = []

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
        memories: inout [KBCompileMemoryRef],
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
            memories.append(KBCompileMemoryRef(id: id, content: saved.content))
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

    private static func decodePayload(_ file: KBCompileFile) throws -> Data {
        switch (file.text, file.base64) {
        case (.some(let text), nil):
            return Data(text.utf8)
        case (nil, let .some(b64)):
            guard let data = Data(base64Encoded: b64) else {
                throw KBCompileError.invalidBase64
            }
            return data
        case (.none, .none):
            throw KBCompileError.missingPayload
        case (.some, .some):
            throw KBCompileError.bothPayloadsSet
        }
    }

    private static func isTextLike(contentType: String) -> Bool {
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? contentType.lowercased()
        return mime.hasPrefix("text/")
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
