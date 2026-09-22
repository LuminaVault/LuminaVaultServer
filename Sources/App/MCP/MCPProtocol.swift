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
    static let serverVersion = "0.2.0"

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

    `health_query`, `calendar_query`, `reminders_list`, `calendar_create` and
    `reminder_create` reach the user's own Apple Health, Calendar (Apple and
    Google) and Reminders. They work only when the user allowed that domain,
    and only for agent keys the user granted personal data. The two create
    tools change the user's phone: confirm with the user first.
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
    static let defaultReadChars = 20000
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
    /// Reads or changes the user's own Health / Calendar / Reminders rather
    /// than a vault. Always runs as the caller, never as a shared vault, and
    /// an agent key only reaches it when the user allowed personal data.
    var personal = false
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

        // MARK: Personal data — the user's own, never a shared vault's.

        MCPTool(
            name: "health_query",
            title: "Health trends",
            description: """
            Daily totals and averages of the user's synced Apple Health data \
            (steps, heart rate, HRV, sleep, active energy, …). Pass `metric` for \
            one HealthKit type, or omit it for all. Fails when the user has not \
            allowed Health access.
            """,
            inputSchema: object(
                properties: [
                    "metric": schema("string", "HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount."),
                    "days": intSchema("Days back to cover (1-365).", minimum: 1, maximum: 365, default: 30),
                ],
                required: []
            ),
            writes: false,
            personal: true
        ),
        MCPTool(
            name: "calendar_query",
            title: "Upcoming events",
            description: """
            Upcoming events from the user's Apple and Google calendars, soonest \
            first. Fails when the user has not allowed Calendar access.
            """,
            inputSchema: object(
                properties: [
                    "days": intSchema("Days ahead to cover (1-90).", minimum: 1, maximum: 90, default: 7),
                ],
                required: []
            ),
            writes: false,
            personal: true
        ),
        MCPTool(
            name: "reminders_list",
            title: "Open reminders",
            description: """
            The user's open Apple Reminders, overdue and upcoming, soonest due \
            first (at most 100). Fails when the user has not allowed Reminders access.
            """,
            inputSchema: object(properties: [:], required: []),
            writes: false,
            personal: true
        ),
        MCPTool(
            name: "calendar_create",
            title: "Create an event",
            description: """
            Create an event in the user's Apple Calendar, on their iPhone. Needs \
            the app reachable and the user's permission to make changes. Confirm \
            with the user before calling.
            """,
            inputSchema: object(
                properties: [
                    "title": schema("string", "Event title."),
                    "start": schema("string", "Start, ISO 8601 with offset."),
                    "end": schema("string", "End, ISO 8601 with offset. Defaults to one hour after start."),
                    "location": schema("string", "Optional location."),
                ],
                required: ["title", "start"]
            ),
            writes: true,
            personal: true
        ),
        MCPTool(
            name: "reminder_create",
            title: "Create a reminder",
            description: """
            Create a reminder in the user's Apple Reminders, on their iPhone. \
            Needs the app reachable and the user's permission to make changes. \
            Confirm with the user before calling.
            """,
            inputSchema: object(
                properties: [
                    "title": schema("string", "Reminder title."),
                    "notes": schema("string", "Optional notes."),
                    "due": schema("string", "Optional due date, ISO 8601 with offset."),
                ],
                required: ["title"]
            ),
            writes: true,
            personal: true
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
                    // Calling a create tool twice makes two events.
                    "idempotentHint": .bool(!(tool.personal && tool.writes)),
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
