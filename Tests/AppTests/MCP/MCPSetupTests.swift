@testable import App
import Foundation
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
