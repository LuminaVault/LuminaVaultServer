import Foundation
import Hummingbird
import Logging

/// MCP over Streamable HTTP at `POST /v1/mcp`.
///
/// This is the surface that lets Claude Code, Cursor, or any MCP client ground
/// on a user's own vault. It is a thin JSON-RPC adapter: it parses the
/// envelope, checks bounds, and hands off to `MCPService`. No retrieval logic
/// lives here.
///
/// The one thing it owns that NexusOS does not have to: **tenancy**. NexusOS
/// binds loopback and serves a single workspace with no authentication. This
/// server is multi-tenant, so the vault a call operates on comes from the
/// caller's JWT (and `X-Vault-ID` for shared vaults) on every single request —
/// never from server state, never from a tool argument.
struct MCPController {
    let service: MCPService
    let vaultAccess: VaultAccessService
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: handle)
    }

    @Sendable
    func handle(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let body = try await request.body.collect(upTo: 1024 * 1024)
        let decoder = JSONDecoder()

        let rpc: MCPRequest
        do {
            rpc = try decoder.decode(MCPRequest.self, from: body)
        } catch {
            return try Self.encode(.failure(id: nil, .parseError("request is not valid JSON-RPC")))
        }

        // Notifications (no id) get an accepted-with-no-body reply, per spec.
        let isNotification = rpc.id == nil

        do {
            guard let result = try await dispatch(rpc, request: request, ctx: ctx) else {
                return Response(status: .accepted)
            }
            if isNotification { return Response(status: .accepted) }
            return try Self.encode(.success(id: rpc.id, result))
        } catch let error as MCPError {
            if isNotification { return Response(status: .accepted) }
            return try Self.encode(.failure(id: rpc.id, error))
        } catch {
            // Never leak an internal message to an agent that will repeat it
            // to the user; the detail goes to our logs instead.
            logger.error("mcp.internalError method=\(rpc.method): \(error)")
            if isNotification { return Response(status: .accepted) }
            return try Self.encode(.failure(id: rpc.id, .internalError("tool execution failed")))
        }
    }

    /// Returns nil when the method is a notification we accept and ignore.
    private func dispatch(
        _ rpc: MCPRequest,
        request: Request,
        ctx: AppRequestContext
    ) async throws -> JSONValue? {
        switch rpc.method {
        case "initialize":
            return .object([
                "protocolVersion": .string(MCPProtocol.version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string(MCPProtocol.serverName),
                    "title": .string(MCPProtocol.serverTitle),
                    "version": .string(MCPProtocol.serverVersion),
                ]),
                "instructions": .string(MCPProtocol.instructions),
            ])

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "ping":
            return .object([:])

        case "tools/list":
            return .object(["tools": MCPToolCatalog.listing()])

        case "tools/call":
            return try await callTool(rpc, request: request, ctx: ctx)

        default:
            throw MCPError.methodNotFound("method '\(rpc.method)' is not supported")
        }
    }

    private func callTool(
        _ rpc: MCPRequest,
        request: Request,
        ctx: AppRequestContext
    ) async throws -> JSONValue {
        guard let params = rpc.params?.objectValue,
              let name = params["name"]?.stringValue
        else {
            throw MCPError.invalidParams("tools/call requires a `name`")
        }
        guard let tool = MCPToolCatalog.tool(named: name) else {
            throw MCPError.methodNotFound("unknown tool '\(name)'")
        }
        let arguments = params["arguments"]?.objectValue ?? [:]

        // Reject unknown arguments here as well as in the advertised schema:
        // a client that ignores `additionalProperties: false` must not get a
        // silently different behavior from one that honors it.
        if let unknown = unknownArgument(tool: tool, arguments: arguments) {
            throw MCPError.invalidParams("unknown argument '\(unknown)' for tool '\(name)'")
        }

        // Tenancy: resolved per call from the JWT, with write intent for the
        // one tool that writes derived state.
        let access = try await vaultAccess.resolve(
            request: request,
            context: ctx,
            requiring: tool.writes ? .write : .read
        )
        let tenantID = access.vaultID

        let result = try await service.call(name: name, arguments: arguments, tenantID: tenantID)
        let isError = result.objectValue?["isError"]?.boolValue ?? false

        // MCP wants both a structured payload and a text rendering; clients
        // vary in which they show.
        let text = (try? String(data: JSONEncoder().encode(result), encoding: .utf8)) ?? "{}"
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": result,
            "isError": .bool(isError),
        ])
    }

    /// First argument name not present in the tool's schema, if any.
    private func unknownArgument(tool: MCPTool, arguments: [String: JSONValue]) -> String? {
        guard let properties = tool.inputSchema.objectValue?["properties"]?.objectValue else { return nil }
        return arguments.keys.sorted().first { properties[$0] == nil }
    }

    private static func encode(_ response: MCPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: buffer)
        )
    }
}
