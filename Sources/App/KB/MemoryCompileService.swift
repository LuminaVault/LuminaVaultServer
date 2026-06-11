import Crypto
import FluentKit
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
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

struct InternalMemoryCompileResult {
    let writtenFiles: [InternalKBCompileWrittenFile]
    let memories: [InternalKBCompileMemoryRef]
    let summary: String
}

enum MemoryCompileError: Error {
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
actor MemoryCompileService {
    let vaultPaths: VaultPathService
    let transport: any HermesChatTransport
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let defaultModel: String
    let logger: Logger
    let maxFileSize: Int
    let maxBatchBytes: Int
    let maxToolIterations: Int

    /// Max chars of a single file's text fed to the extraction LLM (the lead of
    /// an enriched article — enough for durable facts, small enough to keep the
    /// prompt clean and the JSON response untruncated).
    static let maxBlockChars = 8000
    /// HER-288 — progress publisher used to fan-out `.preparing`,
    /// `.thinking`, and `.memorySaved` events over the per-tenant WS
    /// channel. Defaults to `NoopMemoryCompileProgressPublisher` so unit tests
    /// and call-sites that don't care about progress need not wire one up.
    let progress: any MemoryCompileProgressPublisher

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
        progress: any MemoryCompileProgressPublisher = NoopMemoryCompileProgressPublisher()
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
        self.progress = progress
    }

    func compileExistingVaultFiles(
        tenantID: UUID,
        sessionKey: String,
        rows: [VaultFile],
        hint: String?,
        runId: UUID
    ) async throws -> InternalMemoryCompileResult {
        guard !rows.isEmpty else { throw MemoryCompileError.noFiles }

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        var writtenFiles: [InternalKBCompileWrittenFile] = []
        var compiledTextBlocks: [(path: String, content: String, contentType: String)] = []
        var totalBytes = 0
        var rowIDs: [UUID] = []
        // Vault rows whose backing file is gone from disk (orphans — e.g.
        // captured before a vault-volume reset). Skipped, then stamped
        // processed at the end so they stop blocking every future compile and
        // drop out of the pending count.
        var missingRowIDs: [UUID] = []
        // Link captures still being enriched — counted so we can tell the
        // client "N still enriching" and so we don't mark them processed.
        var deferredEnriching = 0

        for row in rows {
            let rowID = try row.requireID()
            // A freshly-captured link is just the "# [Pending Enrichment]"
            // skeleton until URLEnrichmentService fills the full article async.
            // Compiling it now yields nothing, so DEFER it: skip without
            // marking processed, so the next Sync & Learn (after enrichment)
            // picks up the real content.
            if row.metadata?.enrichmentStatus == "pending" {
                deferredEnriching += 1
                continue
            }
            let safeRelative = try VaultController.sanitizePath(row.path)
            let target = try VaultController.resolveInside(rawRoot: rawRoot, relative: safeRelative)
            let payload: Data
            do {
                payload = try Data(contentsOf: target)
            } catch {
                // Missing-file orphan: skip instead of 500-ing the whole batch.
                logger.warning("kb-compile skipping missing vault file path=\(safeRelative) tenant=\(tenantID): \(error)")
                missingRowIDs.append(rowID)
                continue
            }
            guard payload.count <= maxFileSize else {
                throw MemoryCompileError.fileTooLarge(path: safeRelative, limit: maxFileSize)
            }
            totalBytes += payload.count
            guard totalBytes <= maxBatchBytes else {
                throw HTTPError(.contentTooLarge, message: "batch exceeds \(maxBatchBytes) bytes")
            }

            writtenFiles.append(InternalKBCompileWrittenFile(
                path: safeRelative,
                size: payload.count,
                contentType: row.contentType,
                sha256: row.sha256
            ))
            rowIDs.append(rowID)

            if Self.isTextLike(contentType: row.contentType),
               let text = String(data: payload, encoding: .utf8)
            {
                // Cap per-file content fed to the extraction LLM. Enriched links
                // (e.g. a full Jina-fetched wikipedia article) can be 100s of KB
                // of noisy markdown — that bloats the prompt, risks a truncated
                // JSON response, and drowns the model so it extracts nothing. The
                // durable facts live in the lead, so the first ~8K chars suffice.
                let capped = text.count > Self.maxBlockChars
                    ? String(text.prefix(Self.maxBlockChars))
                    : text
                compiledTextBlocks.append((safeRelative, capped, row.contentType))
            }
        }

        // Every pending row was an orphan (no readable file). Clear them so the
        // pending count drains and the user isn't stuck re-tapping Sync & Learn
        // on a batch that can never produce memories. No LLM round-trip.
        if writtenFiles.isEmpty {
            if !missingRowIDs.isEmpty {
                try await markVaultFilesProcessed(ids: missingRowIDs, at: Date())
            }
            logger.warning("kb-compile: no readable vault files (\(missingRowIDs.count) missing, \(deferredEnriching) still enriching) for tenant \(tenantID)")
            return InternalMemoryCompileResult(writtenFiles: [], memories: [], summary: "No readable files to learn from.")
        }

        logger.info("kb-compile processing \(writtenFiles.count) existing files (\(totalBytes) bytes, \(missingRowIDs.count) missing skipped, \(deferredEnriching) still enriching) for tenant \(tenantID)")

        // HER-290 — load the tenant's reject list once per compile so we can
        // dedup `memory_upsert` calls whose content the user already rejected.
        let rejectedHashes = try await loadRejectedHashes(tenantID: tenantID)

        // HER-288 — vault files are on disk, agent loop is about to start.
        // Emit `.preparing` so subscribers can show a "thinking…" surface
        // before the first model round-trip lands.
        await progress.publish(
            .preparing(.init(runId: runId)),
            tenantID: tenantID
        )

        let summary = try await runCompileLoop(
            tenantID: tenantID,
            sessionKey: sessionKey,
            blocks: compiledTextBlocks,
            hint: hint,
            runId: runId,
            rejectedHashes: rejectedHashes
        )
        let completedAt = Date()
        // Stamp both the compiled rows and any skipped orphans so the pending
        // count reflects reality and orphans don't re-enter the next batch.
        try await markVaultFilesProcessed(ids: rowIDs + missingRowIDs, at: completedAt)
        try await refreshSpaceCounters(
            tenantID: tenantID,
            spaceIDs: Set(rows.compactMap(\.spaceID)),
            at: completedAt
        )
        // HER-105 Hybrid — regenerate the human-browsable wiki/ export. Pure
        // side-effect: pgvector memories are the source of truth, so a wiki
        // failure must never fail the compile.
        await rebuildWiki(tenantID: tenantID, at: completedAt)
        return InternalMemoryCompileResult(
            writtenFiles: writtenFiles,
            memories: summary.memories,
            summary: summary.text
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
        sessionKey: String,
        blocks: [(path: String, content: String, contentType: String)],
        hint: String?,
        runId: UUID,
        rejectedHashes: Set<String>
    ) async throws -> CompileSummary {
        // One-shot structured extraction. The previous multi-turn tool-calling
        // loop depended on the model deciding to call `memory_upsert`; routed to
        // Gemini that never happened (it replied in prose), so kb-compile
        // ingested 0 memories. Instead we ask for a single JSON object and
        // persist each memory server-side — deterministic and provider-portable
        // (`response_format: json_object` is honoured by OpenAI-compatible
        // upstreams and mapped to Gemini's responseMimeType).
        let systemPrompt = """
        You are Hermes' kb-compile agent. Extract durable, high-signal memories \
        from the SUBSTANCE of the user's files:
          - For personal notes: the user's preferences, decisions, plans, TODOs, \
            and recurring patterns ("Prefers espresso over filter coffee.").
          - For saved articles / documents / links: the key facts, claims, \
            definitions, and takeaways stated in the material itself \
            ("Stoicism teaches that virtue is the only true good.").
        Write each memory as one concise, self-contained statement of fact in the \
        third person. Never invent — only extract what is actually present. \
        Do NOT write meta-observations about the user saving, capturing, or \
        having a file (e.g. avoid "User captured a Wikipedia article" or "User \
        maintains a knowledge base"). Skip navigation/boilerplate. \
        Return ONLY a JSON object of the form \
        {"memories": ["<memory 1>", "<memory 2>", ...]}, or {"memories": []} when \
        there is nothing durable to store.
        \(hint.map { "User hint: \($0)" } ?? "")
        """

        let bundled: String = if blocks.isEmpty {
            "(No text-shaped files in this batch — only binary assets were written.)"
        } else {
            blocks.map { block in
                "----- FILE: \(block.path) (\(block.contentType)) -----\n\(block.content)"
            }.joined(separator: "\n\n")
        }

        await progress.publish(.thinking(.init(runId: runId, iteration: 1)), tenantID: tenantID)

        let body = ExtractionPayload(
            model: defaultModel,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: bundled),
            ],
            responseFormat: ["type": "json_object"],
            temperature: 0.2,
            stream: false
        )
        let payload = try JSONEncoder().encode(body)
        let raw = try await transport.chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: nil)
        let response = try JSONDecoder().decode(ChatResponseBody.self, from: raw)
        let content = response.choices.first?.message.content ?? ""
        let parsed = Self.parseExtractedMemories(content)
        logger.info("kb-compile extracted \(parsed.count) candidate memories for tenant \(tenantID)")

        var collectedMemories: [InternalKBCompileMemoryRef] = []
        for text in parsed {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // HER-290 — skip content the user previously rejected.
            if rejectedHashes.contains(Self.contentHash(trimmed)) {
                logger.info("kb-compile skipped rejected memory hash for tenant \(tenantID)")
                continue
            }
            let embedding = try await embeddings.embed(trimmed, tenantID: tenantID)
            let saved = try await memories.create(
                tenantID: tenantID,
                content: trimmed,
                embedding: embedding,
                reviewState: "pending"
            )
            let id = try saved.requireID()
            collectedMemories.append(InternalKBCompileMemoryRef(id: id, content: saved.content))
            let dto = MemoryDTO(
                id: id,
                content: saved.content,
                tags: saved.tags ?? [],
                createdAt: saved.createdAt,
                reviewState: saved.reviewState
            )
            await progress.publish(.memorySaved(.init(runId: runId, memory: dto)), tenantID: tenantID)
        }

        let noun = collectedMemories.count == 1 ? "memory" : "memories"
        return CompileSummary(text: "Learned \(collectedMemories.count) \(noun).", memories: collectedMemories)
    }

    /// Lenient parse of the model's JSON memory list. Accepts the canonical
    /// `{"memories": ["a","b"]}`, an array of objects `[{"content":"a"}]`, and a
    /// bare array `["a","b"]`. Tolerates markdown code fences some models add.
    static func parseExtractedMemories(_ raw: String) -> [String] {
        func stringFrom(_ any: Any) -> String? {
            if let str = any as? String { return str }
            if let dict = any as? [String: Any], let c = dict["content"] as? String { return c }
            return nil
        }
        func memories(from obj: Any) -> [String]? {
            if let dict = obj as? [String: Any], let arr = dict["memories"] as? [Any] {
                return arr.compactMap(stringFrom)
            }
            if let arr = obj as? [Any] { return arr.compactMap(stringFrom) }
            return nil
        }

        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json ... ``` fences some models wrap output in.
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 1) direct parse
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let result = memories(from: obj)
        {
            return result
        }
        // 2) without responseMimeType, Gemini may wrap JSON in prose — pull the
        //    outermost {...} or [...] block and parse that.
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let lo = s.firstIndex(of: Character(open)),
               let hi = s.lastIndex(of: Character(close)), lo < hi
            {
                let slice = String(s[lo ... hi])
                if let data = slice.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let result = memories(from: obj)
                {
                    return result
                }
            }
        }
        return []
    }

    private struct ExtractionPayload: Encodable {
        let model: String
        let messages: [AgentMessage]
        let responseFormat: [String: String]
        let temperature: Double?
        let stream: Bool
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case responseFormat = "response_format"
        }
    }

    private func dispatch(
        tenantID: UUID,
        toolCall: ToolCall,
        memories: inout [InternalKBCompileMemoryRef],
        runId: UUID,
        rejectedHashes: Set<String>
    ) async throws -> String {
        guard toolCall.function.name == "memory_upsert" else {
            return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
        }
        guard let argsData = toolCall.function.arguments.data(using: .utf8) else {
            return Self.toolErrorJSON("invalid arguments encoding")
        }
        do {
            let args = try JSONDecoder().decode(MemoryUpsertArgs.self, from: argsData)

            // HER-290 — if the user previously rejected this exact content,
            // suppress the insert and tell the agent so it doesn't retry.
            let hash = Self.contentHash(args.content)
            if rejectedHashes.contains(hash) {
                logger.info("kb-compile skipped rejected memory hash for tenant \(tenantID)")
                return Self.encodeJSON([
                    "status": "skipped",
                    "reason": "user previously rejected this memory; do not propose it again",
                ])
            }

            let embedding = try await embeddings.embed(args.content, tenantID: tenantID)
            let saved = try await self.memories.create(
                tenantID: tenantID,
                content: args.content,
                embedding: embedding,
                reviewState: "pending"
            )
            let id = try saved.requireID()
            memories.append(InternalKBCompileMemoryRef(id: id, content: saved.content))

            // HER-288 — emit the wire-shape DTO that the client also gets
            // from `GET /v1/memory/{id}`. Tags default to [] (the agent
            // loop does not author tags); geo anchor fields stay nil since
            // kb-compile is server-side and has no device location.
            let dto = MemoryDTO(
                id: id,
                content: saved.content,
                tags: saved.tags ?? [],
                createdAt: saved.createdAt,
                reviewState: saved.reviewState
            )
            await progress.publish(
                .memorySaved(.init(runId: runId, memory: dto)),
                tenantID: tenantID
            )

            return Self.encodeJSON(["status": "ok", "id": id.uuidString])
        } catch {
            return Self.toolErrorJSON("memory_upsert failed: \(error)")
        }
    }

    // MARK: - HER-290 reject-list helpers

    /// SHA256 hex digest of UTF-8 content. Stable across whitespace-equal
    /// inputs; matches what `M54_CreateKBCompileRejectList` rows store.
    static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Tenant-scoped `(content_hash)` set for the rejected list, loaded once
    /// at the top of `compileExistingVaultFiles` and threaded through the
    /// agent loop. Empty when the tenant has never rejected anything.
    private func loadRejectedHashes(tenantID: UUID) async throws -> Set<String> {
        let rows = try await KBCompileRejectListEntry.query(on: memories.fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        return Set(rows.map(\.contentHash))
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
                        description: "The memory text to persist verbatim. Should be self-contained."
                    ),
                ],
                required: ["content"]
            )
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

    /// Refreshes the denormalised counters M38 added to `spaces`:
    /// `note_count` (live count of vault_files in the space) and
    /// `last_compiled_at` (timestamp of this compile). Recompute-by-count
    /// instead of incr/decr hooks keeps the write side race-free; cost is
    /// O(distinct spaces touched by this compile).
    ///
    /// Internal (not private) so the integration test can call it directly
    /// without spinning up the full LLM agent loop.
    func refreshSpaceCounters(
        tenantID: UUID,
        spaceIDs: Set<UUID>,
        at date: Date
    ) async throws {
        guard let sql = memories.fluent.db() as? any SQLDatabase, !spaceIDs.isEmpty else { return }
        let literal = "ARRAY[" + spaceIDs.map { "'\($0.uuidString)'" }.joined(separator: ",") + "]::uuid[]"
        try await sql.raw("""
        UPDATE spaces s
           SET note_count = (
             SELECT COUNT(*)::int
               FROM vault_files vf
              WHERE vf.tenant_id = s.tenant_id
                AND vf.space_id = s.id
           ),
           last_compiled_at = \(bind: date)
         WHERE s.tenant_id = \(bind: tenantID)
           AND s.id = ANY(\(unsafeRaw: literal))
        """).run()
    }

    // MARK: - HER-105 Hybrid wiki export

    /// Deterministic full rebuild of the tenant's `wiki/` from current vault
    /// files + non-rejected memories. Best-effort: pgvector memories are the
    /// source of truth, so any failure is logged and swallowed — it must never
    /// fail the compile. Writes `wiki/index.md`, `wiki/<space-slug>.md`,
    /// `wiki/sources/<source-slug>.md`, and `wiki/memories.md`.
    private func rebuildWiki(tenantID: UUID, at date: Date) async {
        do {
            let db = memories.fluent.db()
            let wikiRoot = vaultPaths.wikiDirectory(for: tenantID)
            let rawRoot = vaultPaths.rawDirectory(for: tenantID)
            let fm = FileManager.default
            try fm.createDirectory(at: wikiRoot, withIntermediateDirectories: true)

            let spaces = try await Space.query(on: db, tenantID: tenantID).all()
            var slugByID: [UUID: String] = [:]
            var nameBySlug = ["inbox": "Inbox"]
            for s in spaces {
                guard let id = s.id else { continue }
                slugByID[id] = s.slug
                nameBySlug[s.slug] = s.name
            }

            let files = try await VaultFile.query(on: db, tenantID: tenantID)
                .sort(\.$createdAt, .descending).all()
            let mems = try await Memory.query(on: db, tenantID: tenantID)
                .filter(\.$reviewState != MemoryReviewState.rejected)
                .sort(\.$createdAt, .descending).all()

            // sources/<slug>.md — one page per vault file (text inlined; binary noted)
            let sourcesDir = wikiRoot.appendingPathComponent("sources")
            try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
            var bySlug: [String: [(name: String, page: String)]] = [:]
            for f in files {
                let slug = f.spaceID.flatMap { slugByID[$0] } ?? "inbox"
                let pageSlug = Self.wikiSlug(f.path)
                let name = (f.path as NSString).lastPathComponent
                let body: String = if Self.isTextLike(contentType: f.contentType),
                                      let text = try? String(contentsOf: rawRoot.appendingPathComponent(f.path), encoding: .utf8)
                {
                    text
                } else {
                    "_(binary asset: \(f.contentType))_"
                }
                let page = """
                ---
                source_path: "\(f.path)"
                space: "\(nameBySlug[slug] ?? slug)"
                content_type: "\(f.contentType)"
                ---

                # \(name)

                \(body)
                """
                try? page.data(using: .utf8)?.write(to: sourcesDir.appendingPathComponent("\(pageSlug).md"))
                bySlug[slug, default: []].append((name, pageSlug))
            }

            // <space-slug>.md — per-Space source index
            for (slug, entries) in bySlug {
                let lines = entries.map { "- [\($0.name)](sources/\($0.page).md)" }
                let page = """
                # \(nameBySlug[slug] ?? slug)

                \(entries.count) source\(entries.count == 1 ? "" : "s").

                \(lines.joined(separator: "\n"))
                """
                try? page.data(using: .utf8)?.write(to: wikiRoot.appendingPathComponent("\(slug).md"))
            }

            // memories.md — what Lumina knows
            let memLines = mems.prefix(1000).map { "- \($0.content)" }
            let memPage = """
            # What Lumina knows

            \(mems.count) memories (rejected excluded).

            \(memLines.joined(separator: "\n"))
            """
            try? memPage.data(using: .utf8)?.write(to: wikiRoot.appendingPathComponent("memories.md"))

            // index.md
            let iso = ISO8601DateFormatter().string(from: date)
            var idx = "# Vault wiki\n\nLast compiled: \(iso)\n\n## Spaces\n"
            for slug in bySlug.keys.sorted() {
                idx += "- [\(nameBySlug[slug] ?? slug)](\(slug).md) — \(bySlug[slug]?.count ?? 0) sources\n"
            }
            idx += "\n[What Lumina knows](memories.md) — \(mems.count) memories\n"
            try? idx.data(using: .utf8)?.write(to: wikiRoot.appendingPathComponent("index.md"))

            logger.info("wiki rebuilt tenant=\(tenantID) sources=\(files.count) spaces=\(bySlug.count) memories=\(mems.count)")
        } catch {
            logger.warning("wiki rebuild failed tenant=\(tenantID): \(error)")
        }
    }

    /// Filesystem-safe slug from a vault path's basename (lowercased, non
    /// alphanumerics collapsed to `-`).
    static func wikiSlug(_ path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        var out = ""
        var lastDash = false
        for ch in base {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "untitled" : trimmed
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
