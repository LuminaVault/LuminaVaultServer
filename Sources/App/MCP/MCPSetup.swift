import Foundation

/// Setup snippets a user pastes into Claude Code, Codex, Hermes, or a
/// generic MCP client. Same contract as North's `connections.Setup`:
/// the credential lives in a header, never a URL, and file forms that
/// people commit read the key from the environment.
enum MCPSetup {
    static let envVar = "LUMINA_MCP_TOKEN"
    static let serverName = "luminavault"

    static func mcpURL(publicBaseURL: String) -> String {
        let trimmed = publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed + "/v1/mcp"
    }

    static func instructions(
        kind: AgentClientKind,
        publicBaseURL: String,
        token: String
    ) -> AgentConnectionSetupDTO {
        let url = mcpURL(publicBaseURL: publicBaseURL)
        var setup = AgentConnectionSetupDTO(
            kind: kind,
            url: url,
            token: token,
            configLabel: "connection details",
            configLang: "text",
            config: """
            Transport: streamable HTTP
            URL:       \(url)
            Header:    Authorization: Bearer \(token)
            """,
            prompt: prompt(url: url, token: token)
        )

        switch kind {
        case .claudeCode:
            setup = AgentConnectionSetupDTO(
                kind: kind,
                url: url,
                token: token,
                configLabel: "one command",
                configLang: "bash",
                config: """
                claude mcp add --transport http \(serverName) \(url) \\
                  --header "Authorization: Bearer \(token)"
                """,
                safeLabel: ".mcp.json",
                safeLang: "json",
                safe: """
                {
                  "mcpServers": {
                    "\(serverName)": {
                      "type": "http",
                      "url": "\(url)",
                      "headers": {
                        "Authorization": "Bearer ${\(envVar)}"
                      }
                    }
                  }
                }
                """,
                export: "export \(envVar)=\(token)",
                safeNote: "If that file lives in a git repository, use this version instead and keep the key in your environment — .mcp.json is committed more often than people expect.",
                prompt: prompt(url: url, token: token)
            )
        case .codex:
            setup = AgentConnectionSetupDTO(
                kind: kind,
                url: url,
                token: token,
                configLabel: "one command",
                configLang: "bash",
                config: "codex mcp add \(serverName) --url \(url) --bearer-token-env-var \(envVar)",
                safeLabel: "~/.codex/config.toml",
                safeLang: "toml",
                safe: """
                [mcp_servers.\(serverName)]
                url = "\(url)"
                bearer_token_env_var = "\(envVar)"
                """,
                export: "export \(envVar)=\(token)",
                safeNote: "That command writes this, which you can also write yourself. Codex reads the key from the environment, so the file never contains it.",
                prompt: prompt(url: url, token: token)
            )
        case .hermes:
            setup = AgentConnectionSetupDTO(
                kind: kind,
                url: url,
                token: token,
                configLabel: "shell",
                configLang: "bash",
                config: """
                hermes mcp add \(serverName) --url \(url) --auth header
                # When prompted for the header:
                # Authorization: Bearer \(token)
                """,
                prompt: prompt(url: url, token: token)
            )
        case .other:
            break
        }
        return setup
    }

    static func preview(kind: AgentClientKind, publicBaseURL: String) -> AgentConnectionSetupDTO {
        instructions(kind: kind, publicBaseURL: publicBaseURL, token: AgentConnectionService.placeholderToken)
    }

    private static func prompt(url: String, token: String) -> String {
        [
            "Add an MCP server called \"\(serverName)\" to your own configuration, then confirm it works.",
            "",
            "  Transport: streamable HTTP",
            "  URL:       \(url)",
            "  Header:    Authorization: Bearer \(token)",
            "",
            "Put the credential in a header, never in the URL — URLs end up in logs. Do not register LuminaVault a second time under another name; duplicate tool names across MCP servers make tool selection unpredictable.",
            "",
            "Then verify by listing the tools: you should see status, search, browse, read, recent, links, context and index. Report what you found. Do not call `index` as part of this check — it writes derived state and costs embedding calls.",
            "",
            "Once connected: every call acts as one account — mine. Ask before running `index`, and when you use a passage from `search`, quote the path and line range it gave you rather than inventing one.",
        ].joined(separator: "\n")
    }
}
