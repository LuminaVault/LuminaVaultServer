import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// Executes MCP tools against the tenant's vault.
///
/// Architecture boundary, borrowed from NexusOS: this adapter composes the
/// same services the HTTP controllers use and adds no retrieval logic of its
/// own. The moment it starts building its own queries, MCP becomes a second
/// implementation of LuminaVault that drifts from the first.
///
/// Every method takes an explicit `tenantID` resolved from the caller's JWT.
/// There is no ambient "current vault" — that is the whole difference between
/// this and a loopback single-user MCP server.
struct MCPService: Sendable {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let status: VaultIndexStatusService
    let navigation: VaultNavigationService
    let links: VaultLinkRepository
    let search: HybridMemorySearch
    let embeddings: any EmbeddingService
    let backfill: ChunkBackfillService
    /// Phone writes the app is closed for are queued here, not failed.
    var deviceQueue: DeviceCommandQueue?
    let logger: Logger

    /// Run one tool. Throws only for protocol-level problems; a tool that
    /// legitimately fails (no such document) returns a result the agent can
    /// read and react to.
    func call(
        name: String,
        arguments: [String: JSONValue],
        tenantID: UUID,
        caller: MCPCaller
    ) async throws -> JSONValue {
        switch name {
        case "status": try await JSONValue.encoding(status.status(tenantID: tenantID))
        case "search": try await runSearch(arguments, tenantID: tenantID)
        case "browse": try await runBrowse(arguments, tenantID: tenantID)
        case "read": try await runRead(arguments, tenantID: tenantID)
        case "recent": try await runRecent(arguments, tenantID: tenantID)
        case "links": try await runLinks(arguments, tenantID: tenantID)
        case "context": try await runContext(arguments, tenantID: tenantID)
        case "index": try await runIndex(arguments, tenantID: tenantID)
        case "memory_save": try await runMemorySave(arguments, tenantID: tenantID, caller: caller)
        case "memory_update": try await runMemoryUpdate(arguments, tenantID: tenantID, caller: caller)
        case "memory_forget": try await runMemoryForget(arguments, tenantID: tenantID, caller: caller)
        default: throw MCPError.methodNotFound("unknown tool '\(name)'")
        }
    }

    /// Run one personal-data tool. `userID` is the caller's own account —
    /// the controller never passes a shared vault here.
    func callPersonal(name: String, arguments: [String: JSONValue], userID: UUID) async throws -> JSONValue {
        let tools = PersonalDataTools(fluent: fluent, deviceQueue: deviceQueue)
        let raw: String = switch name {
        case "health_query":
            await tools.healthQuery(
                tenantID: userID,
                metric: arguments["metric"]?.stringValue,
                days: arguments["days"]?.intValue
            )
        case "calendar_query":
            await tools.calendarQuery(tenantID: userID, days: arguments["days"]?.intValue)
        case "reminders_list":
            await tools.remindersList(tenantID: userID)
        case "calendar_create":
            try await tools.calendarCreate(
                tenantID: userID,
                title: requireString(arguments, "title"),
                start: requireString(arguments, "start"),
                end: arguments["end"]?.stringValue,
                location: arguments["location"]?.stringValue
            )
        case "reminder_create":
            try await tools.reminderCreate(
                tenantID: userID,
                title: requireString(arguments, "title"),
                notes: arguments["notes"]?.stringValue,
                due: arguments["due"]?.stringValue
            )
        default:
            throw MCPError.methodNotFound("unknown tool '\(name)'")
        }
        logger.info("mcp.personal tool=\(name) user=\(userID)")
        return Self.toolResult(fromPersonalJSON: raw)
    }

    /// Shapes `PersonalDataTools` JSON as an MCP result: a refused or failed
    /// call becomes `isError` with the reason, so the agent can tell the user
    /// what to allow instead of retrying.
    static func toolResult(fromPersonalJSON raw: String) -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              var object = value.objectValue
        else {
            return .object(["isError": .bool(true), "message": .string("tool returned no result")])
        }
        if object["status"]?.stringValue == "error" {
            object["isError"] = .bool(true)
            object["message"] = object["reason"] ?? .string("tool failed")
        }
        return .object(object)
    }

    // MARK: - Tools

    private func runSearch(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPError.invalidParams("query is required and must be a non-empty string")
        }
        guard query.count <= MCPLimits.maxQueryLength else {
            throw MCPError.invalidParams("query must be at most \(MCPLimits.maxQueryLength) characters")
        }
        let limit = try MCPLimits.validate(
            arguments["limit"]?.intValue ?? MCPLimits.defaultSearchLimit,
            name: "limit",
            maximum: MCPLimits.maxSearchLimit
        )

        let spaceID = try await resolveSpace(arguments["space"]?.stringValue, tenantID: tenantID)
        let embedding = try await embeddings.embed(query, tenantID: tenantID)
        let hits = try await search.search(
            tenantID: tenantID,
            query: query,
            queryEmbedding: embedding,
            limit: limit,
            spaceID: spaceID
        )

        return .object([
            "query": .string(query),
            "total": .number(Double(hits.count)),
            "results": .array(hits.map { hit in
                var row: [String: JSONValue] = [
                    "memoryID": .string(hit.id.uuidString),
                    "text": .string(hit.content),
                ]
                if let snippet = hit.snippet {
                    row["snippet"] = .string(snippet)
                }
                if let citation = hit.citation {
                    // The locator is the point of this tool. Flattened rather
                    // than nested so it is hard for a model to miss.
                    row["path"] = citation.path.map { .string($0) } ?? .null
                    row["headingPath"] = .array(citation.headingPath.map { .string($0) })
                    row["startLine"] = .number(Double(citation.startLine))
                    row["endLine"] = .number(Double(citation.endLine))
                    row["cite"] = .string(citation.displayTrail)
                } else {
                    // Explicitly absent, so "no citation" reads as a fact
                    // rather than an oversight the model might fill in.
                    row["path"] = .null
                    row["cite"] = .null
                }
                return .object(row)
            }),
        ])
    }

    // MARK: - Memory writes

    private var memories: MemoryRepository {
        MemoryRepository(fluent: fluent)
    }

    /// Saves one durable fact, preference or decision. Exact repeats return
    /// the existing memory rather than a second copy, so an agent that saves
    /// the same thing every session does not fill the vault with duplicates.
    private func runMemorySave(
        _ arguments: [String: JSONValue],
        tenantID: UUID,
        caller: MCPCaller
    ) async throws -> JSONValue {
        let content = try memoryContent(arguments)
        let spaceID = try await resolveSpace(arguments["space"]?.stringValue, tenantID: tenantID)
        let tags = try memoryTags(arguments)

        if let existing = try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$content == content)
            .filter(\.$reviewState != MemoryReviewState.rejected)
            .first()
        {
            return try .object([
                "memoryID": .string(existing.requireID().uuidString),
                "duplicate": .bool(true),
                "message": .string("An identical memory already exists; nothing was added."),
            ])
        }

        let embedding = try await embeddings.embed(content, tenantID: tenantID)
        let memory = try await memories.create(
            tenantID: tenantID,
            content: content,
            embedding: embedding,
            tags: tags,
            spaceID: spaceID,
            contribution: caller.contribution(.create)
        )
        memory.createdByUserID = caller.userID
        memory.updatedByUserID = caller.userID
        try await memory.update(on: fluent.db())
        let memoryID = try memory.requireID()
        await backfill.indexer.indexBestEffort(
            tenantID: tenantID,
            memoryID: memoryID,
            vaultFileID: nil,
            spaceID: spaceID,
            sourcePath: nil,
            content: content
        )
        logger.info("mcp.memory.save tenant=\(tenantID) memory=\(memoryID) connection=\(caller.connectionID?.uuidString ?? "session")")
        return .object([
            "memoryID": .string(memoryID.uuidString),
            "duplicate": .bool(false),
        ])
    }

    /// Replaces a memory's text. The old chunks go with it, so a correction
    /// is what later searches see.
    private func runMemoryUpdate(
        _ arguments: [String: JSONValue],
        tenantID: UUID,
        caller: MCPCaller
    ) async throws -> JSONValue {
        let memoryID = try memoryID(arguments)
        let content = try memoryContent(arguments)
        let embedding = try await embeddings.embed(content, tenantID: tenantID)
        let updated = try await memories.updateContent(
            tenantID: tenantID,
            id: memoryID,
            content: content,
            embedding: embedding,
            contribution: caller.contribution(.update)
        )
        guard updated, let row = try await memories.find(tenantID: tenantID, id: memoryID) else {
            return Self.notFound(memoryID)
        }
        row.updatedByUserID = caller.userID
        try await row.update(on: fluent.db())
        await backfill.indexer.indexBestEffort(
            tenantID: tenantID,
            memoryID: memoryID,
            vaultFileID: nil,
            spaceID: row.spaceID,
            sourcePath: nil,
            content: content
        )
        logger.info("mcp.memory.update tenant=\(tenantID) memory=\(memoryID) connection=\(caller.connectionID?.uuidString ?? "session")")
        return .object(["memoryID": .string(memoryID.uuidString), "updated": .bool(true)])
    }

    private func runMemoryForget(
        _ arguments: [String: JSONValue],
        tenantID: UUID,
        caller: MCPCaller
    ) async throws -> JSONValue {
        let memoryID = try memoryID(arguments)
        guard try await memories.forget(tenantID: tenantID, id: memoryID) else {
            return Self.notFound(memoryID)
        }
        logger.info("mcp.memory.forget tenant=\(tenantID) memory=\(memoryID) connection=\(caller.connectionID?.uuidString ?? "session")")
        return .object(["memoryID": .string(memoryID.uuidString), "forgotten": .bool(true)])
    }

    private func memoryContent(_ arguments: [String: JSONValue]) throws -> String {
        let content = (arguments["content"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MCPError.invalidParams("content is required and must be a non-empty string")
        }
        guard content.count <= MCPLimits.maxMemoryLength else {
            throw MCPError.invalidParams("content must be at most \(MCPLimits.maxMemoryLength) characters")
        }
        return content
    }

    private func memoryID(_ arguments: [String: JSONValue]) throws -> UUID {
        guard let raw = arguments["memoryID"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("memoryID is required and must be a UUID from search or memory_save")
        }
        return id
    }

    private func memoryTags(_ arguments: [String: JSONValue]) throws -> [String]? {
        guard let value = arguments["tags"] else { return nil }
        guard case let .array(items) = value else {
            throw MCPError.invalidParams("tags must be an array of strings")
        }
        let tags = try items.map { item in
            guard let tag = item.stringValue?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else {
                throw MCPError.invalidParams("tags must be non-empty strings")
            }
            return tag
        }
        guard tags.count <= MCPLimits.maxMemoryTags else {
            throw MCPError.invalidParams("at most \(MCPLimits.maxMemoryTags) tags")
        }
        return tags.isEmpty ? nil : tags
    }

    /// A Space slug from a tool argument. `inbox`, or nothing, is unfiled.
    /// An unknown slug is the agent's mistake and gets a readable error with
    /// the slugs that do exist, rather than a silent save to the inbox.
    private func resolveSpace(_ slug: String?, tenantID: UUID) async throws -> UUID? {
        guard let slug = slug?.trimmingCharacters(in: .whitespaces), !slug.isEmpty, slug != "inbox" else {
            return nil
        }
        let spaces = try await Space.query(on: fluent.db(), tenantID: tenantID).all()
        guard let space = spaces.first(where: { $0.slug == slug }) else {
            let known = spaces.map(\.slug).sorted().joined(separator: ", ")
            throw MCPError.invalidParams("unknown space '\(slug)'. Known spaces: \(known.isEmpty ? "none" : known), or inbox")
        }
        return try space.requireID()
    }

    private static func notFound(_ memoryID: UUID) -> JSONValue {
        .object([
            "isError": .bool(true),
            "message": .string("no memory \(memoryID.uuidString) in this vault"),
        ])
    }

    private func runBrowse(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        let limit = try MCPLimits.validate(
            arguments["limit"]?.intValue ?? MCPLimits.defaultBrowseLimit,
            name: "limit",
            maximum: MCPLimits.maxBrowseLimit
        )
        var query = VaultFile.query(on: fluent.db(), tenantID: tenantID)
        if let prefix = arguments["pathPrefix"]?.stringValue, !prefix.isEmpty {
            query = query.filter(\.$path >= prefix).filter(\.$path < prefix + "\u{FFFF}")
        }
        let files = try await query.sort(\.$path).limit(limit).all()

        return try .object([
            "count": .number(Double(files.count)),
            "documents": .array(files.map { file in
                try .object([
                    "path": .string(file.path),
                    "sizeBytes": .number(Double(file.sizeBytes)),
                    "vaultFileID": .string(file.requireID().uuidString),
                ])
            }),
        ])
    }

    private func runRead(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        let path = try requirePath(arguments)
        let maxChars = try MCPLimits.validate(
            arguments["maxChars"]?.intValue ?? MCPLimits.defaultReadChars,
            name: "maxChars",
            maximum: MCPLimits.maxReadChars
        )
        guard let file = try await file(tenantID: tenantID, path: path) else {
            return notFound(path)
        }

        // Read the source file, not the reassembled chunks: line numbers in a
        // citation refer to the file a user would open, and overlapping chunks
        // would duplicate text.
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        guard let url = try? VaultController.resolveInside(rawRoot: rawRoot, relative: file.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return .object([
                "isError": .bool(true),
                "path": .string(file.path),
                "message": .string("document is indexed but its file could not be read"),
            ])
        }

        let truncated = text.count > maxChars
        return .object([
            "path": .string(file.path),
            "content": .string(truncated ? String(text.prefix(maxChars)) : text),
            "truncated": .bool(truncated),
            "totalChars": .number(Double(text.count)),
        ])
    }

    private func runRecent(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        let limit = try MCPLimits.validate(
            arguments["limit"]?.intValue ?? MCPLimits.defaultRecentLimit,
            name: "limit",
            maximum: MCPLimits.maxRecentLimit
        )
        let files = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$updatedAt, .descending)
            .limit(limit)
            .all()

        let formatter = ISO8601DateFormatter()
        return .object([
            "count": .number(Double(files.count)),
            "documents": .array(files.map { file in
                var row: [String: JSONValue] = ["path": .string(file.path)]
                if let updated = file.updatedAt {
                    row["updatedAt"] = .string(formatter.string(from: updated))
                }
                return .object(row)
            }),
        ])
    }

    private func runLinks(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        let path = try requirePath(arguments)
        guard let file = try await file(tenantID: tenantID, path: path) else {
            return notFound(path)
        }
        let vaultFileID = try file.requireID()
        let outgoing = try await links.outgoing(tenantID: tenantID, vaultFileID: vaultFileID)
        let incoming = try await links.incoming(tenantID: tenantID, vaultFileID: vaultFileID)
        return try .object([
            "path": .string(file.path),
            "outgoing": JSONValue.encoding(outgoing),
            "incoming": JSONValue.encoding(incoming),
        ])
    }

    private func runContext(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        let path = try requirePath(arguments)
        let siblingLimit = try MCPLimits.validate(
            arguments["siblingLimit"]?.intValue ?? MCPLimits.defaultContextSiblingLimit,
            name: "siblingLimit",
            maximum: MCPLimits.maxContextSiblingLimit
        )
        guard let file = try await file(tenantID: tenantID, path: path) else {
            return notFound(path)
        }
        return try await JSONValue.encoding(
            navigation.context(
                tenantID: tenantID,
                vaultFileID: file.requireID(),
                siblingLimit: siblingLimit
            )
        )
    }

    private func runIndex(_ arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        let batchSize = try MCPLimits.validate(
            arguments["batchSize"]?.intValue ?? ChunkBackfillService.defaultBatchSize,
            name: "batchSize",
            maximum: 200
        )
        let result = try await backfill.backfill(tenantID: tenantID, batchSize: batchSize)
        logger.info("mcp.index tenant=\(tenantID) scanned=\(result.scanned) indexed=\(result.indexed)")
        return try JSONValue.encoding(result)
    }

    // MARK: - Helpers

    private func requireString(_ arguments: [String: JSONValue], _ name: String) throws -> String {
        guard let value = arguments[name]?.stringValue, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPError.invalidParams("\(name) is required and must be a non-empty string")
        }
        return value
    }

    private func requirePath(_ arguments: [String: JSONValue]) throws -> String {
        guard let path = arguments["path"]?.stringValue, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPError.invalidParams("path is required and must be a non-empty string")
        }
        return path
    }

    private func file(tenantID: UUID, path: String) async throws -> VaultFile? {
        try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$path == ChunkIDs.normalize(path))
            .first()
    }

    /// A missing document is a tool-level outcome, not a transport failure:
    /// the agent should be able to try another path without the call erroring.
    private func notFound(_ path: String) -> JSONValue {
        .object([
            "isError": .bool(true),
            "path": .string(path),
            "message": .string("no document at that path — use `browse` or `search` to find the exact path"),
        ])
    }
}
