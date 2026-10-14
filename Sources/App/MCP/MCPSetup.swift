import Foundation
import LuminaVaultShared

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
            prompt: prompt(kind: kind, url: url, token: token)
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
                prompt: prompt(kind: kind, url: url, token: token)
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
                prompt: prompt(kind: kind, url: url, token: token)
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
                prompt: prompt(kind: kind, url: url, token: token)
            )
        case .other:
            break
        }
        return setup
    }

    static func preview(kind: AgentClientKind, publicBaseURL: String) -> AgentConnectionSetupDTO {
        instructions(kind: kind, publicBaseURL: publicBaseURL, token: AgentConnectionService.placeholderToken)
    }

    private static func prompt(kind: AgentClientKind, url: String, token: String) -> String {
        [
            "Add an MCP server called \"\(serverName)\" to your own configuration, then confirm it works.",
            "",
            "  Transport: streamable HTTP",
            "  URL:       \(url)",
            "  Header:    Authorization: Bearer \(token)",
            "",
            "Put the credential in a header, never in the URL — URLs end up in logs. Do not register LuminaVault a second time under another name; duplicate tool names across MCP servers make tool selection unpredictable.",
            "",
            "Then verify by listing the tools: you should see status, search, browse, read, recent, links, context, index, memory_save, memory_update and memory_forget, plus the health, calendar and reminders tools. Report what you found. Do not call `index` or any memory tool as part of this check — they write.",
            "",
            "Once connected: every call acts as one account — mine. Ask before running `index`, and when you use a passage from `search`, quote the path and line range it gave you rather than inventing one.",
            "",
            "Finally, add the block below to \(instructionsHome(kind)), so you use LuminaVault without being asked each session. Keep everything already there; if a \"LuminaVault memory\" section exists, replace only that section. Show me the change before you save it.",
            "",
            memoryHabit,
        ].joined(separator: "\n")
    }

    /// Where each client keeps instructions it reads at the start of every
    /// session. Connecting over MCP does not install them.
    static func instructionsHome(_ kind: AgentClientKind) -> String {
        switch kind {
        case .claudeCode: "my CLAUDE.md (~/.claude/CLAUDE.md for every project)"
        case .codex: "my AGENTS.md (~/.codex/AGENTS.md for every project)"
        case .hermes: "your persistent memory or instructions, the place you read at the start of every session"
        case .other: "the instructions file or setting you read at the start of every session"
        }
    }

    /// The memory habit an agent keeps across sessions. It never asks the
    /// agent to edit SOUL.md: that is the user's, and a BYO-Hermes server
    /// refuses writes to it anyway.
    static let memoryHabit = """
    ## LuminaVault memory
    LuminaVault (MCP server "\(serverName)") is my long-term memory across sessions and tools.
    - Before substantial work, `search` it for my preferences, decisions and context on the topic.
    - Search before saving. If a memory already says it, correct it with `memory_update` instead of saving another.
    - Save with `memory_save`: decisions I confirmed, durable preferences, and facts about me or my work that will matter next time. One plain statement per memory, filed with `space` when one fits.
    - Do not save secrets or credentials, passing remarks, your own guesses, or anything I ask you not to keep.
    - Use `memory_forget` only after I agree.
    - My current instructions beat anything stored. Say when an answer relies on a memory.
    - If a save is refused because this key is read-only, carry on and tell me what you would have saved.
    """
}
