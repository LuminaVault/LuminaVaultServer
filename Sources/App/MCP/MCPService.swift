import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
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
    let logger: Logger

    /// Run one tool. Throws only for protocol-level problems; a tool that
    /// legitimately fails (no such document) returns a result the agent can
    /// read and react to.
    func call(name: String, arguments: [String: JSONValue], tenantID: UUID) async throws -> JSONValue {
        switch name {
        case "status": try await JSONValue.encoding(status.status(tenantID: tenantID))
        case "search": try await runSearch(arguments, tenantID: tenantID)
        case "browse": try await runBrowse(arguments, tenantID: tenantID)
        case "read": try await runRead(arguments, tenantID: tenantID)
        case "recent": try await runRecent(arguments, tenantID: tenantID)
        case "links": try await runLinks(arguments, tenantID: tenantID)
        case "context": try await runContext(arguments, tenantID: tenantID)
        case "index": try await runIndex(arguments, tenantID: tenantID)
        default: throw MCPError.methodNotFound("unknown tool '\(name)'")
        }
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

        let embedding = try await embeddings.embed(query, tenantID: tenantID)
        let hits = try await search.search(
            tenantID: tenantID,
            query: query,
            queryEmbedding: embedding,
            limit: limit
        )

        return .object([
            "query": .string(query),
            "total": .number(Double(hits.count)),
            "results": .array(hits.map { hit in
                var row: [String: JSONValue] = [
                    "memoryID": .string(hit.id.uuidString),
                    "text": .string(hit.content),
                ]
                if let snippet = hit.snippet { row["snippet"] = .string(snippet) }
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

        return .object([
            "count": .number(Double(files.count)),
            "documents": .array(try files.map { file in
                .object([
                    "path": .string(file.path),
                    "sizeBytes": .number(Double(file.sizeBytes)),
                    "vaultFileID": .string(try file.requireID().uuidString),
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
        return .object([
            "path": .string(file.path),
            "outgoing": try JSONValue.encoding(outgoing),
            "incoming": try JSONValue.encoding(incoming),
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
