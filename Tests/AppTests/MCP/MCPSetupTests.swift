@testable import App
import Foundation
import LuminaVaultShared
import Testing

struct MCPSetupTests {
    private let base = "https://api.example.com"
    private let token = "lv_TESTTOKEN"

    @Test
    func `mcp URL is the public base plus /v1/mcp`() {
        #expect(MCPSetup.mcpURL(publicBaseURL: "https://api.example.com/") == "https://api.example.com/v1/mcp")
        #expect(MCPSetup.mcpURL(publicBaseURL: "https://api.example.com") == "https://api.example.com/v1/mcp")
    }

    @Test
    func `Claude Code CLI form uses a header, not the URL`() {
        let setup = MCPSetup.instructions(kind: .claudeCode, publicBaseURL: base, token: token)
        #expect(setup.config.contains("claude mcp add --transport http luminavault https://api.example.com/v1/mcp"))
        #expect(setup.config.contains(#"--header "Authorization: Bearer lv_TESTTOKEN""#))
        #expect(!setup.config.contains("https://api.example.com/v1/mcp?token="))
    }

    @Test
    func `Claude Code git-safe form has no literal key`() throws {
        let setup = MCPSetup.instructions(kind: .claudeCode, publicBaseURL: base, token: token)
        let data = try #require(setup.safe?.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = parsed?["mcpServers"] as? [String: Any]
        let entry = servers?["luminavault"] as? [String: Any]
        let headers = entry?["headers"] as? [String: String]
        #expect(entry?["type"] as? String == "http")
        #expect(entry?["url"] as? String == "https://api.example.com/v1/mcp")
        #expect(headers?["Authorization"] == "Bearer ${LUMINA_MCP_TOKEN}")
        #expect(setup.safe?.contains(token) == false)
        #expect(setup.export?.contains(token) == true)
    }

    @Test
    func `Codex CLI names the env var instead of inlining the key`() {
        let setup = MCPSetup.instructions(kind: .codex, publicBaseURL: base, token: token)
        #expect(setup.config.contains("codex mcp add luminavault --url https://api.example.com/v1/mcp"))
        #expect(setup.config.contains("--bearer-token-env-var LUMINA_MCP_TOKEN"))
        #expect(!setup.config.contains(token))
        #expect(setup.safe?.contains(token) == false)
        #expect(setup.export?.contains(token) == true)
        #expect(setup.safe?.contains("bearer_token_env_var = \"LUMINA_MCP_TOKEN\"") == true)
    }

    @Test
    func `Hermes form uses a header prompt`() {
        let setup = MCPSetup.instructions(kind: .hermes, publicBaseURL: base, token: token)
        #expect(setup.config.contains("hermes mcp add luminavault --url https://api.example.com/v1/mcp --auth header"))
        #expect(setup.config.contains("Authorization: Bearer lv_TESTTOKEN"))
    }

    @Test
    func `every client's prompt installs the memory habit where that client reads it`() {
        let homes: [AgentClientKind: String] = [
            .claudeCode: "CLAUDE.md",
            .codex: "AGENTS.md",
            .hermes: "persistent memory",
            .other: "every session",
        ]
        for kind in AgentClientKind.allCases {
            let prompt = MCPSetup.instructions(kind: kind, publicBaseURL: base, token: token).prompt
            #expect(prompt.contains(MCPSetup.memoryHabit), "\(kind) prompt must carry the habit")
            #expect(prompt.contains(homes[kind] ?? "?"), "\(kind) prompt must say where to put it")
            #expect(prompt.contains("Keep everything already there"), "\(kind) must not overwrite instructions")
        }
    }

    @Test
    func `the habit never asks an agent to edit SOUL`() {
        // SOUL.md is the user's, and a BYO-Hermes server refuses writes to it.
        #expect(!MCPSetup.memoryHabit.localizedCaseInsensitiveContains("soul"))
        #expect(!MCPProtocol.instructions.localizedCaseInsensitiveContains("soul"))
    }

    @Test
    func `every tool the prompt and instructions name is a real tool`() {
        // Backticked names in agent-facing text must be a tool or one of its
        // arguments, or an agent is told to use something that is not there.
        let tools = Set(MCPToolCatalog.all.map(\.name))
        let arguments = Set(MCPToolCatalog.all.flatMap { tool in
            tool.inputSchema.objectValue?["properties"]?.objectValue?.keys.map(\.self) ?? []
        })
        let known = tools.union(arguments)
        let texts = [
            MCPSetup.memoryHabit,
            MCPProtocol.instructions,
            MCPSetup.instructions(kind: .claudeCode, publicBaseURL: base, token: token).prompt,
        ]
        for text in texts {
            for name in Self.backticked(text) where name.allSatisfy({ $0.isLowercase || $0 == "_" }) {
                #expect(known.contains(name), "`\(name)` is not an MCP tool or argument")
            }
        }
        #expect(Self.backticked(MCPSetup.memoryHabit).isSuperset(of: ["search", "memory_save", "memory_update", "memory_forget"]))
    }

    private static func backticked(_ text: String) -> Set<String> {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        return Set(stride(from: 1, to: parts.count, by: 2).map { String(parts[$0]) })
    }

    @Test
    func `preview uses the loud placeholder, not a real token shape`() {
        let setup = MCPSetup.preview(kind: .claudeCode, publicBaseURL: base)
        #expect(setup.token == AgentConnectionService.placeholderToken)
        #expect(!setup.token.hasPrefix(AgentConnectionService.tokenPrefix))
        #expect(setup.prompt.contains(AgentConnectionService.placeholderToken))
    }

    @Test
    func `prompt tells the agent not to write during verification`() {
        let setup = MCPSetup.instructions(kind: .other, publicBaseURL: base, token: token)
        #expect(setup.prompt.contains("status, search, browse"))
        #expect(setup.prompt.contains("Do not call `index`"))
        #expect(setup.prompt.contains("never in the URL"))
    }
}
