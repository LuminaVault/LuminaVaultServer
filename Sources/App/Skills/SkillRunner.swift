import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit
import LuminaVaultShared

/// How a skill was triggered. Recorded on `skill_run_log` for audit.
enum SkillTrigger: Hashable {
    case manual
    case cron
    case event(name: String, payload: [String: String] = [:])
}

/// Outcome of a single skill execution. Persisted to `skill_run_log` by
/// `SkillRunner` and surfaced on the `POST /v1/skills/:name/run` response.
struct SkillRunResult: Codable, Hashable {
    let runID: UUID
    let status: String // "ok" | "error"
    let error: String?
    let modelUsed: String?
    let mtokIn: Int
    let mtokOut: Int
    let startedAt: Date
    let endedAt: Date
}

/// Runs a `SkillManifest` against the Hermes agent loop with strict
/// tool gating: dispatch is enforced server-side against the manifest's
/// `allowed-tools`. A skill that didn't declare `memory_upsert` cannot
/// invoke it — the LLM sees a tool-error and cannot bypass.
///
/// Output dispatch (per `outputs[].kind`) writes to vault, queues APNS,
/// upserts memory, or rewrites the source vault file. Both `started_at`
/// and `ended_at` plus `mtok_in`/`mtok_out` are persisted for cost
/// attribution (UsageMeter integration follows in HER-148 billing pass).
///
/// Mirrors `HermesMemoryService.runAgent` while enforcing per-skill tool
/// capabilities before any server-side dispatch.
actor SkillRunner {
    private let catalog: SkillCatalog
    private let transport: any HermesChatTransport
    private let memories: MemoryRepository
    private let embeddings: any EmbeddingService
    private let apns: APNSNotificationService
    private let defaultModel: String
    private let fluent: Fluent
    private let vaultPaths: VaultPathService
    private let capGuard: SkillRunCapGuard
    private let eventBus: EventBus
    private let logger: Logger
    private var eventSubscriptions: [Task<Void, Never>] = []

    init(
        catalog: SkillCatalog,
        transport: any HermesChatTransport,
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        apns: APNSNotificationService,
        defaultModel: String,
        fluent: Fluent,
        vaultPaths: VaultPathService,
        capGuard: SkillRunCapGuard,
        eventBus: EventBus,
        logger: Logger,
    ) {
        self.catalog = catalog
        self.transport = transport
        self.memories = memories
        self.embeddings = embeddings
        self.apns = apns
        self.defaultModel = defaultModel
        self.fluent = fluent
        self.vaultPaths = vaultPaths
        self.capGuard = capGuard
        self.eventBus = eventBus
        self.logger = logger
    }

    /// HER-171: subscribe to every event type the runner cares about.
    /// Idempotent — repeated calls are no-ops. Cancels prior subscriptions
    /// first so a hot-reload path doesn't double-subscribe.
    ///
    /// HER-171 scope: log receipt only. HER-169 replaces these loops with
    /// real on_event skill dispatch (catalog lookup by tenant → manifests
    /// whose `metadata.on_event` includes the event type → run()).
    func startEventSubscriptions() {
        for task in eventSubscriptions {
            task.cancel()
        }
        eventSubscriptions.removeAll()
        for type in SkillEventType.allCases {
            let stream = eventBus.subscribe(eventType: type)
            let log = logger
            let task = Task<Void, Never> {
                for await event in stream {
                    log.info("skills.runner received event=\(event.type.rawValue) tenant=\(event.tenantID.uuidString) payloadKeys=\(event.payload.keys.sorted().joined(separator: ","))")
                    // HER-169: load tenant's catalog → filter by on_event →
                    // dispatch each matching skill via run(skill:tenantID:...).
                }
            }
            eventSubscriptions.append(task)
        }
        logger.info("skills.runner event subscriptions started: \(SkillEventType.allCases.count) streams")
    }

    /// Cancels every active subscription Task. Safe to call multiple times.
    /// Wired from the App lifecycle on shutdown so streams don't leak.
    func stopEventSubscriptions() {
        for task in eventSubscriptions {
            task.cancel()
        }
        eventSubscriptions.removeAll()
    }

    /// Runs the skill and returns the result. Persists to `skill_run_log`
    /// + updates `skills_state.last_*` columns.
    ///
    /// HER-193 plug-in points (HER-169 wires them):
    /// 1. Before LLM dispatch — `capGuard.checkAndIncrement(...)`;
    ///    `.deny` becomes `SkillRunCapExceededError`.
    /// 2. After LLM/output dispatch fails — `capGuard.recordFailure(...)`
    ///    so the slot is refunded.
    func run(
        skill: SkillManifest,
        tenantID: UUID,
        profileUsername: String,
        trigger: SkillTrigger,
    ) async throws -> SkillRunResult {
        try await run(
            skill: skill,
            tenantID: tenantID,
            tier: "trial",
            profileUsername: profileUsername,
            trigger: trigger,
        )
    }

    func run(
        skill: SkillManifest,
        tenantID: UUID,
        tier: String,
        profileUsername: String,
        trigger: SkillTrigger,
    ) async throws -> SkillRunResult {
        let startedAt = Date()
        let runID = UUID()
        let decision = try await capGuard.checkAndIncrement(tenantID: tenantID, tier: tier, manifest: skill)
        if case let .deny(retryAfter) = decision {
            throw SkillRunCapExceededError(retryAfter: retryAfter)
        }

        var modelUsed: String?
        var mtokIn = 0
        var mtokOut = 0
        do {
            let outcome = try await runAgent(
                skill: skill,
                tenantID: tenantID,
                profileUsername: profileUsername,
                trigger: trigger,
                mtokIn: &mtokIn,
                mtokOut: &mtokOut,
                modelUsed: &modelUsed,
            )
            try await dispatchOutputs(
                skill: skill,
                tenantID: tenantID,
                profileUsername: profileUsername,
                trigger: trigger,
                content: outcome.summary,
            )
            let endedAt = Date()
            let result = SkillRunResult(
                runID: runID,
                status: "ok",
                error: nil,
                modelUsed: modelUsed,
                mtokIn: mtokIn,
                mtokOut: mtokOut,
                startedAt: startedAt,
                endedAt: endedAt,
            )
            try await persist(result: result, skill: skill, tenantID: tenantID)
            return result
        } catch {
            try? await capGuard.recordFailure(tenantID: tenantID, manifest: skill)
            let endedAt = Date()
            let message = String(describing: error)
            logger.error("skills.runner run failed skill=\(skill.name) tenant=\(tenantID.uuidString): \(message)")
            let result = SkillRunResult(
                runID: runID,
                status: "error",
                error: message,
                modelUsed: modelUsed,
                mtokIn: mtokIn,
                mtokOut: mtokOut,
                startedAt: startedAt,
                endedAt: endedAt,
            )
            try? await persist(result: result, skill: skill, tenantID: tenantID)
            throw error
        }
    }

    // MARK: - Agent loop

    private struct AgentOutcome {
        var summary: String
    }

    private enum AvailableTool: String, CaseIterable {
        case memoryUpsert = "memory_upsert"
        case sessionSearch = "session_search"
        case vaultRead = "vault_read"
    }

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
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
            self.name = name
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

    private struct ChatUsage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    private struct ChatResponseBody: Decodable {
        let id: String
        let model: String
        let choices: [ChatResponseChoice]
        let usage: ChatUsage?
    }

    private struct MemoryUpsertArgs: Decodable {
        let content: String
        let sourceVaultFileId: UUID?

        enum CodingKeys: String, CodingKey {
            case content
            case sourceVaultFileId = "source_vault_file_id"
        }
    }

    private struct SessionSearchArgs: Decodable {
        let query: String
        let limit: Int?
    }

    private struct VaultReadArgs: Decodable {
        let path: String?
        let vaultFileId: UUID?

        enum CodingKeys: String, CodingKey {
            case path
            case vaultFileId = "vault_file_id"
        }
    }

    private func runAgent(
        skill: SkillManifest,
        tenantID: UUID,
        profileUsername: String,
        trigger: SkillTrigger,
        mtokIn: inout Int,
        mtokOut: inout Int,
        modelUsed: inout String?,
    ) async throws -> AgentOutcome {
        let allowed = Set(skill.allowedTools)
        let tools = AvailableTool.allCases
            .filter { allowed.contains($0.rawValue) }
            .map(Self.definition)
        var conversation: [AgentMessage] = [
            .init(role: "system", content: """
            You are running LuminaVault skill `\(skill.name)`.
            Follow the skill body. Tool availability is enforced server-side;
            if a tool call returns an error, continue without trying to bypass it.
            Return the final output body as markdown or concise plain text.
            """),
            .init(role: "user", content: """
            Trigger: \(Self.triggerDescription(trigger))

            Skill body:
            \(skill.body)
            """),
        ]

        for _ in 0 ..< 6 {
            let body = ChatRequestBody(
                model: defaultModel,
                messages: conversation,
                tools: tools,
                toolChoice: "auto",
                temperature: 0.2,
                stream: false,
            )
            let payload = try JSONEncoder().encode(body)
            let metadata = try await transport.chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername)
            let response = try JSONDecoder().decode(ChatResponseBody.self, from: metadata.data)
            modelUsed = response.model
            Self.accumulateUsage(metadata: metadata, response: response, mtokIn: &mtokIn, mtokOut: &mtokOut)
            guard let choice = response.choices.first else {
                throw HTTPError(.badGateway, message: "skill runner got no choices")
            }
            let assistant = choice.message
            conversation.append(assistant)
            if let calls = assistant.toolCalls, !calls.isEmpty {
                for call in calls {
                    let result = try await dispatch(
                        tenantID: tenantID,
                        allowedTools: allowed,
                        toolCall: call,
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
            return AgentOutcome(summary: assistant.content ?? "")
        }
        throw HTTPError(.badGateway, message: "skill runner agent did not converge")
    }

    private func dispatch(
        tenantID: UUID,
        allowedTools: Set<String>,
        toolCall: ToolCall,
    ) async throws -> String {
        guard allowedTools.contains(toolCall.function.name) else {
            return Self.toolErrorJSON("tool \(toolCall.function.name) not allowed by this skill manifest")
        }
        guard let argsData = toolCall.function.arguments.data(using: .utf8) else {
            return Self.toolErrorJSON("invalid arguments encoding")
        }
        let decoder = JSONDecoder()
        switch toolCall.function.name {
        case AvailableTool.memoryUpsert.rawValue:
            do {
                let args = try decoder.decode(MemoryUpsertArgs.self, from: argsData)
                let saved = try await persistMemory(
                    tenantID: tenantID,
                    content: args.content,
                    sourceVaultFileID: args.sourceVaultFileId,
                )
                return Self.encodeJSON([
                    "status": "ok",
                    "id": (try? saved.requireID().uuidString) ?? "",
                ])
            } catch {
                return Self.toolErrorJSON("memory_upsert failed: \(error)")
            }
        case AvailableTool.sessionSearch.rawValue:
            do {
                let args = try decoder.decode(SessionSearchArgs.self, from: argsData)
                let embedding = try await embeddings.embed(args.query)
                let hits = try await memories.semanticSearch(
                    tenantID: tenantID,
                    queryEmbedding: embedding,
                    limit: max(1, min(args.limit ?? 5, 20)),
                )
                let serializable = hits.map { hit in
                    [
                        "id": hit.id.uuidString,
                        "content": hit.content,
                        "distance": String(hit.distance),
                    ]
                }
                return Self.encodeJSON(["status": "ok", "results": serializable])
            } catch {
                return Self.toolErrorJSON("session_search failed: \(error)")
            }
        case AvailableTool.vaultRead.rawValue:
            do {
                let args = try decoder.decode(VaultReadArgs.self, from: argsData)
                let row = try await resolveVaultFile(tenantID: tenantID, id: args.vaultFileId, path: args.path)
                let content = try readVaultFile(tenantID: tenantID, path: row.path)
                return Self.encodeJSON(["status": "ok", "path": row.path, "content": content])
            } catch {
                return Self.toolErrorJSON("vault_read failed: \(error)")
            }
        default:
            return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
        }
    }

    // MARK: - Output dispatch

    private func dispatchOutputs(
        skill: SkillManifest,
        tenantID: UUID,
        profileUsername: String,
        trigger: SkillTrigger,
        content: String,
    ) async throws {
        for output in skill.outputs {
            switch output.kind {
            case .memo:
                try await persistVaultFile(
                    tenantID: tenantID,
                    path: output.path ?? "memos/\(Self.dateStamp())/\(Self.slug(skill.name)).md",
                    content: content,
                    contentType: "text/markdown",
                )
            case .apnsDigest:
                try await apns.notifyDigest(userID: tenantID, username: profileUsername, body: content)
            case .apnsNudge:
                try await apns.notifyNudge(userID: tenantID, username: profileUsername, body: content)
            case .memoryEmit:
                _ = try await persistMemory(tenantID: tenantID, content: content, sourceVaultFileID: sourceVaultFileID(from: trigger))
            case .vaultRewrite:
                guard let id = sourceVaultFileID(from: trigger) else {
                    throw HTTPError(.badRequest, message: "vault_rewrite output requires source vault file id")
                }
                let row = try await resolveVaultFile(tenantID: tenantID, id: id, path: nil)
                try await persistVaultFile(
                    tenantID: tenantID,
                    path: row.path,
                    content: content,
                    contentType: row.contentType,
                    existing: row,
                )
            }
        }
    }

    private func persistMemory(tenantID: UUID, content: String, sourceVaultFileID: UUID?) async throws -> Memory {
        let embedding = try await embeddings.embed(content)
        return try await memories.create(
            tenantID: tenantID,
            content: content,
            embedding: embedding,
            sourceVaultFileID: sourceVaultFileID,
        )
    }

    private func persistVaultFile(
        tenantID: UUID,
        path: String,
        content: String,
        contentType: String,
        existing: VaultFile? = nil,
    ) async throws {
        let safePath = try Self.validateRelativePath(path)
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = rawRoot.appendingPathComponent(safePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: target, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let row: VaultFile?
        if let existing {
            row = existing
        } else {
            row = try await VaultFile
                .query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$path == safePath)
                .first()
        }
        if let row {
            row.sizeBytes = Int64(data.count)
            row.sha256 = digest
            row.contentType = contentType
            try await row.update(on: fluent.db())
        } else {
            let row = VaultFile(
                tenantID: tenantID,
                path: safePath,
                contentType: contentType,
                sizeBytes: Int64(data.count),
                sha256: digest,
            )
            try await row.save(on: fluent.db())
        }
    }

    private func resolveVaultFile(tenantID: UUID, id: UUID?, path: String?) async throws -> VaultFile {
        if let id {
            if let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$id == id)
                .first()
            {
                return row
            }
            throw HTTPError(.notFound, message: "vault file not found")
        }
        if let path {
            let safePath = try Self.validateRelativePath(path)
            if let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$path == safePath)
                .first()
            {
                return row
            }
        }
        throw HTTPError(.badRequest, message: "vault file id or path required")
    }

    private func readVaultFile(tenantID: UUID, path: String) throws -> String {
        let safePath = try Self.validateRelativePath(path)
        let url = vaultPaths.rawDirectory(for: tenantID).appendingPathComponent(safePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceVaultFileID(from trigger: SkillTrigger) -> UUID? {
        guard case let .event(_, payload) = trigger else { return nil }
        return payload[SkillEvent.PayloadKey.sourceVaultFileID].flatMap(UUID.init(uuidString:))
            ?? payload[SkillEvent.PayloadKey.vaultFileID].flatMap(UUID.init(uuidString:))
    }

    // MARK: - Persistence

    private func persist(result: SkillRunResult, skill: SkillManifest, tenantID: UUID) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "skill runner requires SQL driver")
        }
        try await sql.raw("""
        INSERT INTO skill_run_log
            (id, tenant_id, source, name, started_at, ended_at, status, error, model_used, mtok_in, mtok_out)
        VALUES
            (\(bind: result.runID), \(bind: tenantID), \(bind: skill.source.rawValue), \(bind: skill.name),
             \(bind: result.startedAt), \(bind: result.endedAt), \(bind: result.status), \(bind: result.error),
             \(bind: result.modelUsed), \(bind: result.mtokIn), \(bind: result.mtokOut))
        """).run()
        try await sql.raw("""
        INSERT INTO skills_state
            (tenant_id, source, name, enabled, last_run_at, last_status, last_error)
        VALUES
            (\(bind: tenantID), \(bind: skill.source.rawValue), \(bind: skill.name), TRUE,
             \(bind: result.endedAt), \(bind: result.status), \(bind: result.error))
        ON CONFLICT (tenant_id, source, name) DO UPDATE
            SET last_run_at = EXCLUDED.last_run_at,
                last_status = EXCLUDED.last_status,
                last_error = EXCLUDED.last_error
        """).run()
    }

    // MARK: - Helpers

    private static func definition(for tool: AvailableTool) -> ToolDefinition {
        switch tool {
        case .memoryUpsert:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Persist a memory for the current tenant.",
                parameters: .init(
                    properties: [
                        "content": .init(type: "string", description: "Memory text to persist."),
                        "source_vault_file_id": .init(type: "string", description: "Optional source vault file UUID."),
                    ],
                    required: ["content"],
                ),
            ))
        case .sessionSearch:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Semantic-search the current tenant's memories.",
                parameters: .init(
                    properties: [
                        "query": .init(type: "string", description: "Natural language query."),
                        "limit": .init(type: "integer", description: "Maximum memories, 1-20."),
                    ],
                    required: ["query"],
                ),
            ))
        case .vaultRead:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Read one current-tenant vault file by path or id.",
                parameters: .init(
                    properties: [
                        "path": .init(type: "string", description: "Vault path relative to raw root."),
                        "vault_file_id": .init(type: "string", description: "Vault file UUID."),
                    ],
                    required: [],
                ),
            ))
        }
    }

    private static func accumulateUsage(
        metadata: HermesChatTransportMetadata,
        response: ChatResponseBody,
        mtokIn: inout Int,
        mtokOut: inout Int,
    ) {
        if let value = firstIntHeader(["x-mtok-in", "x-usage-mtok-in", "x-luminavault-mtok-in"], in: metadata.headers) {
            mtokIn += value
        } else if let prompt = response.usage?.promptTokens {
            mtokIn += prompt
        }
        if let value = firstIntHeader(["x-mtok-out", "x-usage-mtok-out", "x-luminavault-mtok-out"], in: metadata.headers) {
            mtokOut += value
        } else if let completion = response.usage?.completionTokens {
            mtokOut += completion
        }
    }

    private static func firstIntHeader(_ names: [String], in headers: [String: String]) -> Int? {
        let lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        for name in names {
            if let raw = lower[name], let value = Int(raw) {
                return value
            }
        }
        return nil
    }

    private static func triggerDescription(_ trigger: SkillTrigger) -> String {
        switch trigger {
        case .manual: "manual"
        case .cron: "cron"
        case let .event(name, payload): "event:\(name) payload:\(payload)"
        }
    }

    private static func validateRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains("..")
        else {
            throw HTTPError(.badRequest, message: "invalid vault path")
        }
        return trimmed
    }

    private static func dateStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    private static func slug(_ value: String) -> String {
        var out = ""
        for ch in value.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == " " || ch == "-" || ch == "_" {
                if !out.isEmpty, out.last != "-" { out.append("-") }
            }
        }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "skill" : String(out.prefix(64))
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
