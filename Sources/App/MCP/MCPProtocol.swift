import Foundation

/// JSON-RPC 2.0 envelopes and the MCP tool catalog.
///
/// Hand-rolled rather than pulled from an SDK. The wire format is small and
/// stable, and every alternative would add a dependency that owns transport
/// and auth — which is exactly the part we cannot delegate, because unlike
/// NexusOS (loopback, single user, unauthenticated) every call here must be
/// scoped to one tenant.
enum MCPProtocol {
    /// The spec revision this server implements.
    static let version = "2025-06-18"
    static let serverName = "luminavault"
    static let serverTitle = "LuminaVault"
    /// Version of this MCP surface, not of the server as a whole. Bump when
    /// the tool set or a schema changes, so a client can tell what it is
    /// talking to.
    static let serverVersion = "0.1.0"

    /// What an agent is told this server is for.
    static let instructions = """
    LuminaVault exposes one user's knowledge vault: markdown documents, a
    chunk index with line-level citations, and a wiki-link graph.

    Every tool except `index` is read-only and never modifies source
    documents. `index` writes derived state only (chunks and links); it never
    rewrites the user's markdown.

    A conservative sequence is: call `status` first; call `index` only when it
    reports drift and the user permits a refresh; use `search` to find
    evidence; then `read`, `links`, or `context` to inspect it. Cite the
    `path` and line range that `search` returns — do not paraphrase a source
    without saying where it came from, and never invent a path or line number
    that a tool did not give you.
    """
}

/// Shared bounds. The same numbers gate the HTTP layer, so an agent and a
/// client cannot be granted different limits for the same operation.
enum MCPLimits {
    static let minLimit = 1
    static let maxSearchLimit = 50
    static let defaultSearchLimit = 10
    static let maxBrowseLimit = 500
    static let defaultBrowseLimit = 50
    static let maxRecentLimit = 100
    static let defaultRecentLimit = 10
    static let maxContextSiblingLimit = VaultNavigationService.maxSiblingLimit
    static let defaultContextSiblingLimit = VaultNavigationService.defaultSiblingLimit
    /// Characters returned by `read` before truncation is reported.
    static let maxReadChars = 100_000
    static let defaultReadChars = 20_000
    static let maxQueryLength = 1000

    /// Clamp with an explicit error rather than silently, so an agent asking
    /// for 5000 results learns the ceiling instead of quietly getting 50.
    static func validate(_ value: Int, name: String, maximum: Int) throws -> Int {
        guard value >= minLimit, value <= maximum else {
            throw MCPError.invalidParams("\(name) must be between \(minLimit) and \(maximum); got \(value)")
        }
        return value
    }
}

// MARK: - JSON-RPC

struct MCPRequest: Decodable, Sendable {
    let jsonrpc: String?
    /// Absent for notifications, which expect no response.
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

struct MCPResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: JSONValue?
    var result: JSONValue?
    var error: MCPErrorBody?

    static func success(id: JSONValue?, _ result: JSONValue) -> MCPResponse {
        MCPResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONValue?, _ error: MCPError) -> MCPResponse {
        MCPResponse(id: id, result: nil, error: error.body)
    }
}

struct MCPErrorBody: Encodable, Sendable {
    let code: Int
    let message: String
}

/// Protocol-level failures. Tool failures are *not* these — a tool that
/// cannot find a document returns a normal result with `isError: true`, so
/// the agent can react instead of the transport blowing up.
enum MCPError: Error, Sendable {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)

    var body: MCPErrorBody {
        switch self {
        case let .parseError(message): MCPErrorBody(code: -32700, message: message)
        case let .invalidRequest(message): MCPErrorBody(code: -32600, message: message)
        case let .methodNotFound(message): MCPErrorBody(code: -32601, message: message)
        case let .invalidParams(message): MCPErrorBody(code: -32602, message: message)
        case let .internalError(message): MCPErrorBody(code: -32603, message: message)
        }
    }
}

// MARK: - Tool catalog

/// One advertised tool.
///
/// Schemas are strict (`additionalProperties: false`) so a typo in an argument
/// name is rejected by the client rather than silently ignored by us.
struct MCPTool: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    /// Surfaced as an MCP tool annotation. `false` is a promise: this tool
    /// cannot change anything the user would notice.
    let writes: Bool
}

enum MCPToolCatalog {
    static let all: [MCPTool] = [
        MCPTool(
            name: "status",
            title: "Index status",
            description: """
            Is the searchable index up to date with the vault? Reports document, \
            chunk and link counts, how many documents are unindexed or stale, and \
            a human-readable reason for each kind of drift.
            """,
            inputSchema: object(properties: [:], required: []),
            writes: false
        ),
        MCPTool(
            name: "search",
            title: "Search the vault",
            description: """
            Hybrid search over the vault: semantic similarity fused with exact \
            keyword matching, so both paraphrase and literal tokens (hostnames, \
            error codes, IDs) are found. Every hit carries the source path, \
            heading trail and line range it came from — cite those.
            """,
            inputSchema: object(
                properties: [
                    "query": schema("string", "What to look for. Plain language or exact terms."),
                    "limit": intSchema(
                        "Maximum hits (\(MCPLimits.minLimit)-\(MCPLimits.maxSearchLimit)).",
                        minimum: MCPLimits.minLimit,
                        maximum: MCPLimits.maxSearchLimit,
                        default: MCPLimits.defaultSearchLimit
                    ),
                ],
                required: ["query"]
            ),
            writes: false
        ),
        MCPTool(
            name: "browse",
            title: "List documents",
            description: "List indexed documents. Use when you need the shape of the vault rather than a text query.",
            inputSchema: object(
                properties: [
                    "pathPrefix": schema("string", "Only documents whose path starts with this."),
                    "limit": intSchema(
                        "Maximum documents (\(MCPLimits.minLimit)-\(MCPLimits.maxBrowseLimit)).",
                        minimum: MCPLimits.minLimit,
                        maximum: MCPLimits.maxBrowseLimit,
                        default: MCPLimits.defaultBrowseLimit
                    ),
                ],
                required: []
            ),
            writes: false
        ),
        MCPTool(
            name: "read",
            title: "Read a document",
            description: """
            Read one document's text by vault-relative path. Bounded: the reply \
            reports whether it was truncated.
            """,
            inputSchema: object(
                properties: [
                    "path": schema("string", "Vault-relative path, as returned by search or browse."),
                    "maxChars": intSchema(
                        "Characters to return (\(MCPLimits.minLimit)-\(MCPLimits.maxReadChars)).",
                        minimum: MCPLimits.minLimit,
                        maximum: MCPLimits.maxReadChars,
                        default: MCPLimits.defaultReadChars
                    ),
                ],
                required: ["path"]
            ),
            writes: false
        ),
        MCPTool(
            name: "recent",
            title: "Recently changed documents",
            description: "Documents modified most recently, newest first.",
            inputSchema: object(
                properties: [
                    "limit": intSchema(
                        "Maximum documents (\(MCPLimits.minLimit)-\(MCPLimits.maxRecentLimit)).",
                        minimum: MCPLimits.minLimit,
                        maximum: MCPLimits.maxRecentLimit,
                        default: MCPLimits.defaultRecentLimit
                    ),
                ],
                required: []
            ),
            writes: false
        ),
        MCPTool(
            name: "links",
            title: "Wiki links and backlinks",
            description: """
            Outgoing [[wiki links]] written in a document, and the backlinks \
            pointing at it. Each link reports whether it resolved, points at \
            nothing, or is ambiguous between several documents.
            """,
            inputSchema: object(
                properties: ["path": schema("string", "Vault-relative path.")],
                required: ["path"]
            ),
            writes: false
        ),
        MCPTool(
            name: "context",
            title: "Evidence packet",
            description: """
            What should be understood alongside a document: its heading \
            structure, its neighbours in the same Space, and the documents it \
            links to and from. Deterministic — no summarisation, no ranking.
            """,
            inputSchema: object(
                properties: [
                    "path": schema("string", "Vault-relative path."),
                    "siblingLimit": intSchema(
                        "Same-Space neighbours (\(MCPLimits.minLimit)-\(MCPLimits.maxContextSiblingLimit)).",
                        minimum: MCPLimits.minLimit,
                        maximum: MCPLimits.maxContextSiblingLimit,
                        default: MCPLimits.defaultContextSiblingLimit
                    ),
                ],
                required: ["path"]
            ),
            writes: false
        ),
        MCPTool(
            name: "index",
            title: "Refresh the index",
            description: """
            Index one batch of documents that are not yet searchable. Writes \
            derived state only — chunks and links — and never modifies the \
            user's markdown. Call repeatedly until `scanned` is 0. Ask the user \
            before running this: it costs embedding calls.
            """,
            inputSchema: object(
                properties: [
                    "batchSize": intSchema(
                        "Documents to index this call (1-200).",
                        minimum: 1,
                        maximum: 200,
                        default: ChunkBackfillService.defaultBatchSize
                    ),
                ],
                required: []
            ),
            writes: true
        ),
    ]

    static func tool(named name: String) -> MCPTool? {
        all.first { $0.name == name }
    }

    /// Advertised shape: `{name, title, description, inputSchema, annotations}`.
    static func listing() -> JSONValue {
        .array(all.map { tool in
            .object([
                "name": .string(tool.name),
                "title": .string(tool.title),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": .object([
                    "readOnlyHint": .bool(!tool.writes),
                    // Nothing here deletes or overwrites user content, including
                    // `index`, which only rebuilds derived rows.
                    "destructiveHint": .bool(false),
                    "idempotentHint": .bool(true),
                ]),
            ])
        })
    }

    // MARK: - Schema helpers

    private static func object(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            // Strict: an unknown argument is a mistake worth surfacing, not
            // something to quietly drop.
            "additionalProperties": .bool(false),
        ])
    }

    private static func schema(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func intSchema(
        _ description: String,
        minimum: Int,
        maximum: Int,
        default defaultValue: Int
    ) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description),
            "minimum": .number(Double(minimum)),
            "maximum": .number(Double(maximum)),
            "default": .number(Double(defaultValue)),
        ])
    }
}
