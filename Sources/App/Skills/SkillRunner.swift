import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// How a skill was triggered. Recorded on `skill_run_log` for audit.
enum SkillTrigger: Hashable {
    case manual
    case cron
    case event(name: String, payload: [String: String] = [:])
}

/// Outcome of a single skill execution. Persisted to `skill_run_log` by
/// `SkillRunner` and surfaced on the `POST /v1/skills/:name/run` response.
struct SkillRunResult: Codable {
    let runID: UUID
    let status: String // "ok" | "error"
    let markdown: String
    /// Jobs P2 — structured native-render blocks (nil when the agent returned
    /// plain markdown). Persisted to `skill_run_log.blocks` and surfaced on
    /// `SkillRunDTO.blocks` for the iOS BlockRenderer.
    let blocks: [LuminaBlock]?
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
    private let usageMeter: UsageMeterService?
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
        usageMeter: UsageMeterService? = nil,
        logger: Logger
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
        self.usageMeter = usageMeter
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
            // HER-200 H3 — `Task.detached` so the indefinite event loop does
            // not inherit buildRouter's top-level task or its task-locals.
            // Cancellation is wired explicitly via `stopEventSubscriptions()`
            // which `.cancel()`s every task in `eventSubscriptions`.
            let task = Task.detached(priority: .utility) {
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
        trigger: SkillTrigger
    ) async throws -> SkillRunResult {
        try await run(
            skill: skill,
            tenantID: tenantID,
            tier: "trial",
            profileUsername: profileUsername,
            trigger: trigger
        )
    }

    func run(
        skill: SkillManifest,
        tenantID: UUID,
        tier: String,
        profileUsername: String,
        trigger: SkillTrigger,
        input: String? = nil,
        arguments: [String: String] = [:]
    ) async throws -> SkillRunResult {
        let startedAt = Date()
        let runID = UUID()
        let decision = try await capGuard.checkAndIncrement(tenantID: tenantID, tier: tier, manifest: skill)
        if case let .deny(retryAfter) = decision {
            throw SkillRunCapExceededError(retryAfter: retryAfter)
        }

        if let usageMeter {
            let budgetDecision = await usageMeter.checkSkillBudget(tenantID: tenantID, skillName: skill.name)
            if case let .deny(retryAfter) = budgetDecision {
                try? await capGuard.recordFailure(tenantID: tenantID, manifest: skill)
                throw UsageCapExceededError(retryAfter: retryAfter)
            }
        }

        var modelUsed: String?
        var mtokIn = 0
        var mtokOut = 0
        let routingUser: User? = (try? await User.find(tenantID, on: fluent.db())) ?? nil
        let routingState: SkillsState? = (try? await SkillsState.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$source == skill.source.rawValue)
            .filter(\.$name == skill.name)
            .first()) ?? nil
        let routingScope = CerberusRequestScope(
            surface: skill.name.hasPrefix("job-") ? .job : .skill,
            spaceID: routingState?.spaceID,
            jobID: skill.name.hasPrefix("job-") ? skill.name : nil
        )
        do {
            let outcome = try await runAgent(
                skill: skill,
                tenantID: tenantID,
                profileUsername: profileUsername,
                trigger: trigger,
                input: input,
                arguments: arguments,
                mtokIn: &mtokIn,
                mtokOut: &mtokOut,
                modelUsed: &modelUsed,
                routingUser: routingUser,
                routingScope: routingScope
            )
            try await dispatchOutputs(
                skill: skill,
                tenantID: tenantID,
                profileUsername: profileUsername,
                trigger: trigger,
                content: outcome.summary
            )
            let endedAt = Date()
            let result = SkillRunResult(
                runID: runID,
                status: "ok",
                markdown: outcome.summary,
                blocks: outcome.blocks,
                error: nil,
                modelUsed: modelUsed,
                mtokIn: mtokIn,
                mtokOut: mtokOut,
                startedAt: startedAt,
                endedAt: endedAt
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
                markdown: "",
                blocks: nil,
                error: message,
                modelUsed: modelUsed,
                mtokIn: mtokIn,
                mtokOut: mtokOut,
                startedAt: startedAt,
                endedAt: endedAt
            )
            try? await persist(result: result, skill: skill, tenantID: tenantID)
            throw error
        }
    }

    // MARK: - Agent loop

    private struct AgentOutcome {
        var summary: String
        var blocks: [LuminaBlock]?
    }

    /// Jobs P2 — the agent may return either plain markdown (existing skills)
    /// or a JSON object `{"markdown": "...", "blocks": [...]}` for native
    /// rendering. Lenient: if the content parses as that shape with blocks,
    /// use them; otherwise treat the whole content as markdown (blocks = nil).
    /// Non-breaking — markdown-only skills are unaffected.
    static func parseAgentOutput(_ content: String) -> (summary: String, blocks: [LuminaBlock]?) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a ```json … ``` fence if present.
        let unfenced: String = {
            guard trimmed.hasPrefix("```") else { return trimmed }
            let inner = trimmed.drop(while: { $0 == "`" })
            let afterTag = inner.drop(while: { $0 != "\n" }).dropFirst()
            if let end = afterTag.range(of: "```", options: .backwards) {
                return String(afterTag[afterTag.startIndex ..< end.lowerBound])
            }
            return String(afterTag)
        }()
        guard unfenced.hasPrefix("{"), let data = unfenced.data(using: .utf8) else {
            return (content, nil)
        }
        struct Envelope: Decodable { let markdown: String?; let blocks: [LuminaBlock]? }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let blocks = env.blocks, !blocks.isEmpty
        else {
            return (content, nil)
        }
        return (env.markdown ?? content, blocks)
    }

    private enum AvailableTool: String, CaseIterable {
        case memoryUpsert = "memory_upsert"
        case sessionSearch = "session_search"
        case vaultRead = "vault_read"
        /// Apple Integration P1 — read the tenant's synced HealthKit data
        /// (gated by per-domain consent). Daily aggregates for trends/correlation.
        case healthQuery = "health_query"
        /// Apple Integration P2 — create a reminder / calendar event on the
        /// user's device via device-RPC (gated by consent + "allow writes").
        case reminderCreate = "reminder_create"
        case calendarCreate = "calendar_create"
        /// Apple Integration P2b — fresh read of upcoming calendar events /
        /// open reminders via device-RPC (gated by consent; read-only).
        case calendarQuery = "calendar_query"
        case remindersList = "reminders_list"
        /// Apple Integration P3 — recent photos analyzed on-device (OCR text);
        /// only derived text leaves the device, never pixels. Read-only.
        case photosSearch = "photos_search"
        /// Apple Integration P4 — the user's current location + place name via
        /// device-RPC (gated by consent; read-only).
        case locationRecent = "location_recent"
        /// Apple Integration P5 — prompt the user to pick documents on their
        /// device; only derived text (PDF/plain-text) is returned, never the
        /// file bytes. Requires Files access + a foregrounded app. Read-only.
        case filesPick = "files_pick"
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

    // swiftlint:disable:next function_parameter_count
    private func runAgent(
        skill: SkillManifest,
        tenantID: UUID,
        profileUsername _: String,
        trigger: SkillTrigger,
        input: String?,
        arguments: [String: String],
        mtokIn: inout Int,
        mtokOut: inout Int,
        modelUsed: inout String?,
        routingUser: User?,
        routingScope: CerberusRequestScope
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

            OUTPUT FORMAT — choose ONE:
            • Plain markdown / concise text (default), OR
            • For data-rich results, a single JSON object:
              {"markdown":"<short fallback>","blocks":[ ... ]}
              where each block is {"type": <kind>, ...fields}. Kinds:
              heading{text,level} · paragraph{text} · markdown{text} ·
              statCard{label,value,delta,trend:"up|down|flat"} ·
              lineChart{series:[{name,points:[{x,y}]}]} · barChart{series} ·
              list{items:[...]} · table{columns:[...],rows:[[...]]} ·
              badge{text} · keyValue{pairs:[{key,value}]} · quote{text} ·
              image{url} · divider. Pick the blocks that best present THIS
              domain (e.g. statCard+lineChart for metrics, table/list for
              collections, markdown for prose). Output ONLY the JSON, no fence.
            """),
            .init(role: "user", content: """
            Trigger: \(Self.triggerDescription(trigger))
            \(Self.inputDescription(input, arguments: arguments))

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
                stream: false
            )
            let payload = try JSONEncoder().encode(body)
            let metadata = try await LLMRoutingContext.$currentUser.withValue(routingUser) {
                try await LLMRoutingContext.$cerberusScope.withValue(routingScope) {
                    try await transport.chatCompletionsWithMetadata(
                        payload: payload,
                        sessionKey: tenantID.uuidString,
                        sessionID: nil
                    )
                }
            }
            let response = try JSONDecoder().decode(ChatResponseBody.self, from: metadata.data)
            modelUsed = response.model
            let mtokInBefore = mtokIn
            let mtokOutBefore = mtokOut
            Self.accumulateUsage(metadata: metadata, response: response, mtokIn: &mtokIn, mtokOut: &mtokOut)

            let inDelta = mtokIn - mtokInBefore
            let outDelta = mtokOut - mtokOutBefore
            if inDelta > 0 || outDelta > 0, let meter = usageMeter {
                let modelTag = "skill:\(skill.name)/\(modelUsed ?? defaultModel)"
                Task { await meter.record(tenantID: tenantID, model: modelTag, tokensIn: inDelta, tokensOut: outDelta) }
            }

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
                        toolCall: call
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
            let parsed = Self.parseAgentOutput(assistant.content ?? "")
            return AgentOutcome(summary: parsed.summary, blocks: parsed.blocks)
        }
        throw HTTPError(.badGateway, message: "skill runner agent did not converge")
    }

    private func dispatch(
        tenantID: UUID,
        allowedTools: Set<String>,
        toolCall: ToolCall
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
                    sourceVaultFileID: args.sourceVaultFileId
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
                let embedding = try await embeddings.embed(args.query, tenantID: tenantID)
                let hits = try await memories.semanticSearch(
                    tenantID: tenantID,
                    queryEmbedding: embedding,
                    limit: max(1, min(args.limit ?? 5, 20))
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
        case AvailableTool.healthQuery.rawValue:
            struct HealthQueryArgs: Decodable { let metric: String?; let days: Int? }
            struct AggRow: Decodable { let event_type: String; let unit: String?; let day: Date; let total: Double?; let avg: Double? }
            do {
                guard let sql = fluent.db() as? any SQLDatabase else {
                    return Self.toolErrorJSON("sql unavailable")
                }
                // Consent gate — the user must have allowed the Health domain.
                let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .health, sql: sql)
                guard allowed else {
                    return Self.toolErrorJSON("health access not allowed by the user")
                }
                let args = (try? decoder.decode(HealthQueryArgs.self, from: argsData)) ?? HealthQueryArgs(metric: nil, days: nil)
                let days = max(1, min(args.days ?? 30, 365))
                let rows: [AggRow] = if let metric = args.metric, !metric.isEmpty {
                    try await sql.raw("""
                    SELECT event_type, unit, date_trunc('day', recorded_at) AS day,
                           SUM(value_numeric) AS total, AVG(value_numeric) AS avg
                    FROM health_events
                    WHERE tenant_id = \(bind: tenantID) AND event_type = \(bind: metric)
                      AND recorded_at >= NOW() - (\(bind: days) * INTERVAL '1 day')
                    GROUP BY event_type, unit, day ORDER BY day
                    """).all(decoding: AggRow.self)
                } else {
                    try await sql.raw("""
                    SELECT event_type, unit, date_trunc('day', recorded_at) AS day,
                           SUM(value_numeric) AS total, AVG(value_numeric) AS avg
                    FROM health_events
                    WHERE tenant_id = \(bind: tenantID)
                      AND recorded_at >= NOW() - (\(bind: days) * INTERVAL '1 day')
                    GROUP BY event_type, unit, day ORDER BY day
                    """).all(decoding: AggRow.self)
                }
                let points = rows.map { r in
                    [
                        "metric": r.event_type,
                        "unit": r.unit ?? "",
                        "day": Self.fileDateStamp(r.day),
                        "total": String(format: "%.2f", r.total ?? 0),
                        "avg": String(format: "%.2f", r.avg ?? 0),
                    ]
                }
                return Self.encodeJSON(["status": "ok", "days": String(days), "points": points])
            } catch {
                return Self.toolErrorJSON("health_query failed: \(error)")
            }
        case AvailableTool.reminderCreate.rawValue:
            struct Args: Decodable { let title: String; let notes: String?; let due: String? }
            do {
                let args = try decoder.decode(Args.self, from: argsData)
                return await deviceWrite(tenantID: tenantID, domain: .reminders, kind: .reminderCreate, payload: [
                    "title": args.title, "notes": args.notes ?? "", "due": args.due ?? "",
                ])
            } catch {
                return Self.toolErrorJSON("reminder_create failed: \(error)")
            }
        case AvailableTool.calendarCreate.rawValue:
            struct Args: Decodable { let title: String; let start: String; let end: String?; let location: String? }
            do {
                let args = try decoder.decode(Args.self, from: argsData)
                return await deviceWrite(tenantID: tenantID, domain: .calendar, kind: .calendarCreate, payload: [
                    "title": args.title, "start": args.start, "end": args.end ?? "", "location": args.location ?? "",
                ])
            } catch {
                return Self.toolErrorJSON("calendar_create failed: \(error)")
            }
        case AvailableTool.calendarQuery.rawValue:
            struct Args: Decodable { let days: Int? }
            struct CalRow: Decodable {
                let title: String
                let starts_at: Date
                let ends_at: Date
                let location: String?
            }
            let args = (try? decoder.decode(Args.self, from: argsData)) ?? Args(days: nil)
            let days = max(1, min(args.days ?? 7, 90))
            guard let sql = fluent.db() as? any SQLDatabase else {
                return Self.toolErrorJSON("sql unavailable")
            }
            // Consent gate — the user must have allowed the Calendar domain.
            let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .calendar, sql: sql)
            guard allowed else {
                return Self.toolErrorJSON("calendar access not allowed by the user")
            }
            // Read the synced cache (all sources — apple_eventkit + google) for the
            // requested day window. Excludes tombstoned (cancelled) rows.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            do {
                let rows = try await sql.raw("""
                SELECT title, starts_at, ends_at, location
                FROM calendar_events
                WHERE tenant_id = \(bind: tenantID)
                  AND status <> 'cancelled'
                  AND starts_at >= NOW()
                  AND starts_at < NOW() + (\(bind: days) * INTERVAL '1 day')
                ORDER BY starts_at ASC
                """).all(decoding: CalRow.self)
                if rows.isEmpty {
                    // Cache miss — fall back to a live device round-trip so the user
                    // still gets an answer before the first sync (or when offline
                    // sync hasn't run). Device-RPC is the fallback, not the path.
                    return await deviceRead(tenantID: tenantID, domain: .calendar, payload: ["days": String(days)])
                }
                let events = rows.map { r in
                    [
                        "title": r.title,
                        "start": iso.string(from: r.starts_at),
                        "end": iso.string(from: r.ends_at),
                        "location": r.location ?? "",
                    ]
                }
                return Self.encodeJSON(["status": "ok", "items": events])
            } catch {
                // On a DB error, fall back to device-RPC rather than failing the tool.
                return await deviceRead(tenantID: tenantID, domain: .calendar, payload: ["days": String(days)])
            }
        case AvailableTool.remindersList.rawValue:
            return await remindersList(tenantID: tenantID)
        case AvailableTool.photosSearch.rawValue:
            struct Args: Decodable { let limit: Int?; let query: String? }
            let args = (try? decoder.decode(Args.self, from: argsData)) ?? Args(limit: nil, query: nil)
            let limit = max(1, min(args.limit ?? 10, 30))
            return await photosSearch(tenantID: tenantID, query: args.query, limit: limit)
        case AvailableTool.locationRecent.rawValue:
            return await deviceRead(tenantID: tenantID, domain: .location, payload: [:])
        case AvailableTool.filesPick.rawValue:
            return await deviceRead(tenantID: tenantID, domain: .files, payload: [:])
        default:
            return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
        }
    }

    /// Apple Integration P2 — gate consent + writes, then round-trip a write
    /// command to the device via the broker and shape the result as tool JSON.
    private func deviceWrite(tenantID: UUID, domain: AppleDataDomain, kind: DeviceCommandKind, payload: [String: String]) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.toolErrorJSON("sql unavailable")
        }
        let (allowed, writes) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: domain, sql: sql)
        guard allowed else { return Self.toolErrorJSON("\(domain.rawValue) access not allowed by the user") }
        guard writes else { return Self.toolErrorJSON("\(domain.rawValue) changes not allowed by the user") }
        do {
            let result = try await DeviceCommandBroker.shared.request(
                tenantID: tenantID,
                command: DeviceCommand(kind: kind, domain: domain, payload: payload)
            )
            guard result.ok else { return Self.toolErrorJSON(result.error ?? "device reported failure") }
            var out = ["status": "ok"]
            for (k, v) in result.payload ?? [:] {
                out[k] = v
            }
            return Self.encodeJSON(out)
        } catch {
            return Self.toolErrorJSON("device did not respond (offline or timed out)")
        }
    }

    /// Apple Reminders selective-sync read path. Serves the persisted
    /// `apple_reminders` cache (open/overdue items, soonest due first) the iOS
    /// client pushes via `POST /v1/reminders/sync`, so Hermes answers without a
    /// live device round-trip. Falls back to a fresh device_fetch when the
    /// cache is empty (device never synced, or just-installed client).
    /// Consent-gated on `.reminders`, same as the device-RPC path.
    private func remindersList(tenantID: UUID) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.toolErrorJSON("sql unavailable")
        }
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .reminders, sql: sql)
        guard allowed else { return Self.toolErrorJSON("reminders access not allowed by the user") }

        struct Row: Decodable { let title: String; let due_at: Date?; let notes: String? }
        let rows: [Row]
        do {
            // Open (incomplete) reminders, overdue + upcoming, soonest due
            // first; NULLs (no due date) sort last. Capped to keep the tool
            // payload bounded.
            rows = try await sql.raw("""
            SELECT title, due_at, notes
            FROM apple_reminders
            WHERE tenant_id = \(bind: tenantID) AND completed = false
            ORDER BY due_at ASC NULLS LAST
            LIMIT 100
            """).all(decoding: Row.self)
        } catch {
            return Self.toolErrorJSON("reminders_list failed: \(error)")
        }

        // Cache miss → fall back to a live device fetch.
        guard !rows.isEmpty else {
            return await deviceRead(tenantID: tenantID, domain: .reminders, payload: [:])
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let items = rows.map { row -> [String: String] in
            var item: [String: String] = ["title": row.title]
            if let due = row.due_at { item["due"] = iso.string(from: due) }
            if let notes = row.notes, !notes.isEmpty { item["notes"] = notes }
            return item
        }
        let itemsJSON = Self.encodeJSON(items)
        return Self.encodeJSON(["status": "ok", "items": itemsJSON])
    }

    /// Apple Integration P2b — gate consent, then round-trip a fresh read
    /// (device_fetch) to the device; returns the device's `items` JSON.
    private func deviceRead(tenantID: UUID, domain: AppleDataDomain, payload: [String: String]) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.toolErrorJSON("sql unavailable")
        }
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: domain, sql: sql)
        guard allowed else { return Self.toolErrorJSON("\(domain.rawValue) access not allowed by the user") }
        do {
            let result = try await DeviceCommandBroker.shared.request(
                tenantID: tenantID,
                command: DeviceCommand(kind: .deviceFetch, domain: domain, payload: payload)
            )
            guard result.ok else { return Self.toolErrorJSON(result.error ?? "device reported failure") }
            return Self.encodeJSON(["status": "ok", "items": result.payload?["items"] ?? "[]"])
        } catch {
            return Self.toolErrorJSON("device did not respond (offline or timed out)")
        }
    }

    /// Apple Photos derived-text recall. When a `query` is given and the tenant
    /// has indexed photos (M81), runs a consent-gated cosine semantic search
    /// over `photo_index` and returns the matching derived text + metadata.
    /// Falls back to a live device fetch when the index is empty (or no query),
    /// so a freshly-onboarded user still gets answers before the first sync.
    private func photosSearch(tenantID: UUID, query: String?, limit: Int) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.toolErrorJSON("sql unavailable")
        }
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .photos, sql: sql)
        guard allowed else { return Self.toolErrorJSON("photos access not allowed by the user") }

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let indexed = await PhotoIndexController.hasRows(tenantID: tenantID, sql: sql)

        // Semantic path: needs both a query and a populated index.
        if !trimmedQuery.isEmpty, indexed {
            do {
                let embedding = try await embeddings.embed(trimmedQuery, tenantID: tenantID)
                let hits = try await PhotoIndexController.semanticSearch(
                    tenantID: tenantID,
                    queryEmbedding: embedding,
                    limit: limit,
                    sql: sql
                )
                let items: [[String: String]] = hits.map { hit in
                    [
                        "taken_at": hit.takenAt.map(Self.fileDateStamp) ?? "",
                        "is_screenshot": hit.isScreenshot ? "true" : "false",
                        "ocr_text": hit.ocrText ?? "",
                        "scene_tags": hit.sceneTags.joined(separator: ", "),
                        "score": String(format: "%.3f", hit.score),
                    ]
                }
                return Self.encodeJSON(["status": "ok", "source": "index", "items": items])
            } catch {
                return Self.toolErrorJSON("photos_search failed: \(error)")
            }
        }

        // Fallback: live device fetch (no query, or nothing indexed yet).
        return await deviceRead(tenantID: tenantID, domain: .photos, payload: ["limit": String(limit)])
    }

    // MARK: - Output dispatch

    private func dispatchOutputs(
        skill: SkillManifest,
        tenantID: UUID,
        profileUsername: String,
        trigger: SkillTrigger,
        content: String
    ) async throws {
        for output in skill.outputs {
            switch output.kind {
            case .memo:
                try await persistVaultFile(
                    tenantID: tenantID,
                    path: output.path ?? "memos/\(Self.dateStamp())/\(Self.slug(skill.name)).md",
                    content: content,
                    contentType: "text/markdown"
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
                    existing: row
                )
            }
        }
    }

    private func persistMemory(tenantID: UUID, content: String, sourceVaultFileID: UUID?) async throws -> Memory {
        let embedding = try await embeddings.embed(content, tenantID: tenantID)
        return try await memories.create(
            tenantID: tenantID,
            content: content,
            embedding: embedding,
            sourceVaultFileID: sourceVaultFileID
        )
    }

    private func persistVaultFile(
        tenantID: UUID,
        path: String,
        content: String,
        contentType: String,
        existing: VaultFile? = nil,
        spaceID: UUID? = nil
    ) async throws {
        let safePath = try Self.validateRelativePath(path)
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = rawRoot.appendingPathComponent(safePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: target, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let row: VaultFile? = if let existing {
            existing
        } else {
            try await VaultFile
                .query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$path == safePath)
                .first()
        }
        if let row {
            row.sizeBytes = Int64(data.count)
            row.sha256 = digest
            row.contentType = contentType
            row.processedAt = nil
            if let spaceID { row.spaceID = spaceID }
            try await row.update(on: fluent.db())
        } else {
            let row = VaultFile(
                tenantID: tenantID,
                spaceID: spaceID,
                path: safePath,
                contentType: contentType,
                sizeBytes: Int64(data.count),
                sha256: digest
            )
            try await row.save(on: fluent.db())
        }
    }

    /// Jobs P4 — file a job's run output into its target Space as a vault file
    /// so the result shows up in the Space browser and the Brain graph (as a
    /// source node under that Space's hub). Best-effort: a job is a vault skill
    /// with a `skills_state.space_id`; non-jobs / spaceless skills no-op, and
    /// any failure is swallowed so it never fails the run.
    private func fileJobResultIfNeeded(result: SkillRunResult, skill: SkillManifest, tenantID: UUID) async {
        guard result.status == "ok",
              !result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sql = fluent.db() as? any SQLDatabase
        else { return }
        struct SpaceRow: Decodable { let space_id: UUID?; let slug: String? }
        let row: SpaceRow? = await (try? sql.raw("""
        SELECT ss.space_id, s.slug
        FROM skills_state ss
        LEFT JOIN spaces s ON s.id = ss.space_id
        WHERE ss.tenant_id = \(bind: tenantID)
          AND ss.source = \(bind: skill.source.rawValue)
          AND ss.name = \(bind: skill.name)
        """).first(decoding: SpaceRow.self)) ?? nil
        guard let spaceID = row?.space_id, let slug = row?.slug else { return }
        let day = Self.fileDateStamp(result.endedAt)
        let path = "\(slug)/jobs/\(skill.name)-\(day).md"
        try? await persistVaultFile(
            tenantID: tenantID,
            path: path,
            content: result.markdown,
            contentType: "text/markdown",
            spaceID: spaceID
        )
    }

    /// `YYYY-MM-DD` in UTC, DateFormatter-free (concurrency-safe).
    static func fileDateStamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
        // Jobs P2 — encode structured blocks to a JSON string for the JSONB
        // column; nil when the run produced plain markdown.
        let blocksJSON: String? = {
            guard let blocks = result.blocks, let data = try? JSONEncoder().encode(blocks) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        try await sql.raw("""
        INSERT INTO skill_run_log
            (id, tenant_id, source, name, started_at, ended_at, status, error, model_used, mtok_in, mtok_out, markdown, blocks)
        VALUES
            (\(bind: result.runID), \(bind: tenantID), \(bind: skill.source.rawValue), \(bind: skill.name),
             \(bind: result.startedAt), \(bind: result.endedAt), \(bind: result.status), \(bind: result.error),
             \(bind: result.modelUsed), \(bind: result.mtokIn), \(bind: result.mtokOut), \(bind: result.markdown),
             \(bind: blocksJSON)::jsonb)
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

        // Jobs P4 — file the result into the job's Space (best-effort).
        await fileJobResultIfNeeded(result: result, skill: skill, tenantID: tenantID)
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
                    required: ["content"]
                )
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
                    required: ["query"]
                )
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
                    required: []
                )
            ))
        case .healthQuery:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Read the user's Apple Health data as daily aggregates (for trends/correlation). Requires the user to have allowed Health access.",
                parameters: .init(
                    properties: [
                        "metric": .init(type: "string", description: "Optional event type to filter (e.g. step_count, sleep, heart_rate). Omit for all."),
                        "days": .init(type: "integer", description: "Lookback window in days, 1-365 (default 30)."),
                    ],
                    required: []
                )
            ))
        case .reminderCreate:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Create a reminder in the user's Apple Reminders. Requires the user to have allowed Reminders access with changes enabled.",
                parameters: .init(
                    properties: [
                        "title": .init(type: "string", description: "Reminder title."),
                        "notes": .init(type: "string", description: "Optional notes/body."),
                        "due": .init(type: "string", description: "Optional ISO-8601 due date-time."),
                    ],
                    required: ["title"]
                )
            ))
        case .calendarCreate:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Create an event in the user's Apple Calendar. Requires the user to have allowed Calendar access with changes enabled.",
                parameters: .init(
                    properties: [
                        "title": .init(type: "string", description: "Event title."),
                        "start": .init(type: "string", description: "ISO-8601 start date-time."),
                        "end": .init(type: "string", description: "ISO-8601 end date-time."),
                        "location": .init(type: "string", description: "Optional location."),
                    ],
                    required: ["title", "start"]
                )
            ))
        case .calendarQuery:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "List the user's upcoming calendar events from the synced server cache (Apple EventKit + Google Calendar), falling back to a live device read when the cache is empty. Requires the user to have allowed Calendar access. Returns a JSON array of {title,start,end,location}.",
                parameters: .init(
                    properties: [
                        "days": .init(type: "integer", description: "How many days ahead to include, 1-90 (default 7)."),
                    ],
                    required: []
                )
            ))
        case .remindersList:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "List the user's open (incomplete) Apple Reminders, overdue and upcoming items soonest-due first. Served from the synced server-side cache when available (falls back to a live device fetch). Requires the user to have allowed Reminders access. Returns a JSON array of {title,due,notes}.",
                parameters: .init(properties: [:], required: [])
            ))
        case .photosSearch:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Search the user's photos by their derived text. Pass `query` for a semantic search over previously-indexed OCR text + scene tags (e.g. \"the screenshot about the flight\", \"a receipt\") — only derived text + metadata are stored server-side, never the images. Omit `query` to analyze the most recent photos live on-device. Requires Photos access. Returns a JSON array of {taken_at, is_screenshot, ocr_text, scene_tags, score}.",
                parameters: .init(
                    properties: [
                        "query": .init(type: "string", description: "Natural-language description of the photo/screenshot to find. Omit to list recent photos instead."),
                        "limit": .init(type: "integer", description: "Maximum results, 1-30 (default 10)."),
                    ],
                    required: []
                )
            ))
        case .locationRecent:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Get the user's current location with a place name. Requires Location access. Returns a JSON array of {lat,lng,place,at}.",
                parameters: .init(properties: [:], required: [])
            ))
        case .filesPick:
            ToolDefinition(function: .init(
                name: tool.rawValue,
                description: "Prompt the user to pick one or more documents on their device; extracted text (from PDFs and plain-text files) is read on-device and only that text is returned, never the file bytes. Requires Files access and the app to be open. Returns a JSON array of {name,type,chars,text}.",
                parameters: .init(properties: [:], required: [])
            ))
        }
    }

    private static func accumulateUsage(
        metadata: HermesChatTransportMetadata,
        response: ChatResponseBody,
        mtokIn: inout Int,
        mtokOut: inout Int
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

    private static func inputDescription(_ input: String?, arguments: [String: String]) -> String {
        var lines: [String] = []
        if let input, !input.isEmpty {
            lines.append("Input: \(input)")
        }
        if !arguments.isEmpty {
            let rendered = arguments
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
            lines.append("Arguments:\n\(rendered)")
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n\n")
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
        while out.last == "-" {
            out.removeLast()
        }
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
