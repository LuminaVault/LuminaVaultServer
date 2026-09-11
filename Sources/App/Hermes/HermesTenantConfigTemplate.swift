import Crypto
import Foundation
import LuminaVaultShared

/// One tenant gateway's decrypted credential config, ready to render into the
/// container's `.env`. `config` keys are the catalog field keys (e.g.
/// `bot_token`); `HermesGatewayCatalog.envVars(_:config:)` maps them to the
/// Hermes env-var names.
struct HermesGatewaySeed: Equatable {
    let gatewayID: HermesGatewayID
    let config: [String: String]
}

/// Points a tenant's Hermes at the LuminaVault audio proxy for speech.
///
/// Hermes' OpenAI speech client is aimed at `baseURL` instead of
/// `api.openai.com`, so transcription passes through our entitlement, rate
/// limiting and usage metering. Without this, audio spend happens inside the
/// container where we can neither see nor bound it.
struct HermesAudioProxySeed: Equatable {
    /// Origin **including** the `/v1` suffix, e.g.
    /// `https://api.luminavault.app/v1`.
    let baseURL: String
    /// Scoped credential from `HermesAudioTokenService`. Written to `.env`,
    /// never to `config.yaml`.
    let token: String
    /// Model name sent upstream. Ours is provider-selected server-side, so
    /// this only has to be a name the OpenAI client accepts.
    var sttModel: String = "whisper-1"
    var ttsModel: String = "tts-1"
    var ttsVoice: String = "lumina"
}

/// HER-254 — embedded `config.yaml` and `.env` templates used to seed each
/// per-tenant container's `/opt/data` volume before `docker run`. Without a
/// seeded config, Hermes boots with defaults that try to enable
/// telegram/discord/whatsapp/email platforms — all of which fail without
/// credentials and produce noisy logs. We narrow the surface to `api_server`
/// (a clean per-tenant OpenAI-compatible HTTP endpoint) and selectively
/// activate messaging gateways the tenant has configured by writing their
/// token env-vars into `.env`.
///
/// Gateway activation is **env-var driven** (Hermes' `gateway run` starts a
/// platform when its token env-var is present — see the
/// `hermes-gateway-env-schema` memory), so credentials go in `.env`, not
/// `config.yaml`. `.env` is written at the volume **root** (`/opt/data/.env`
/// == `HERMES_HOME/.env`, the only path Hermes reads via `get_env_path()`).
///
/// Templates are deterministic given the same inputs. `seed(...)`
/// SHA-256-compares the rendered output against what's on disk and only
/// rewrites on drift, so seeding is idempotent across restarts.
enum HermesTenantConfigTemplate {
    enum SeedError: Swift.Error, Equatable {
        case ioFailure(path: String, underlying: String)
    }

    /// Renders + writes the tenant's `config.yaml` and `.env`. Idempotent:
    /// re-writes only when on-disk SHA-256 differs from the rendered output.
    ///
    /// Hermes loads `config.yaml` from **HERMES_HOME root** (`get_config_path()`
    /// == `/opt/data/config.yaml`) and `.env` from `get_env_path()` ==
    /// `HERMES_HOME/.env` == `/opt/data/.env`. Both are written at the volume
    /// root. (A prior version wrote `.env` to `.hermes/.env`, which Hermes never
    /// reads — `API_SERVER_*` only worked because they're also passed via
    /// `docker --env`. Gateway tokens are NOT passed via `--env`, so the path
    /// must be correct here.) `seed()` runs before every `docker run`, so
    /// existing tenants pick up the corrected paths + any gateway changes on
    /// their next restart via the drift rewrite.
    ///
    /// - Parameter gateways: the tenant's configured messaging gateways; their
    ///   token env-vars are appended to `.env` to activate each platform.
    /// - Parameter mnemosyneEnabled: when `true` (the managed default) the
    ///   config seeds the Mnemosyne MCP server AND disables Hermes' native
    ///   curated memory so Mnemosyne is the single memory layer. When `false`,
    ///   neither is emitted and Hermes falls back to its built-in file memory.
    static func seed(
        volumePath: String,
        apiKey: String,
        defaultModel: String,
        gateways: [HermesGatewaySeed] = [],
        mnemosyneEnabled: Bool = true,
        audioProxy: HermesAudioProxySeed?
    ) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: volumePath,
                withIntermediateDirectories: true
            )
        } catch {
            throw SeedError.ioFailure(path: volumePath, underlying: String(describing: error))
        }
        try writeIfDrifted(
            path: "\(volumePath)/config.yaml",
            content: configYAML(
                defaultModel: defaultModel,
                mnemosyneEnabled: mnemosyneEnabled,
                audioProxy: audioProxy
            )
        )
        try writeIfDrifted(
            path: "\(volumePath)/.env",
            content: envFile(apiKey: apiKey, gateways: gateways, audioProxy: audioProxy)
        )
    }

    /// Atomic write (write-to-tmp + rename) iff the on-disk SHA-256 differs
    /// from the rendered content. No-op otherwise.
    private static func writeIfDrifted(path: String, content: String) throws {
        let desired = Data(content.utf8)
        let desiredDigest = SHA256.hash(data: desired)

        if let existing = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let existingDigest = SHA256.hash(data: existing)
            if existingDigest == desiredDigest {
                return
            }
        }

        let tmpPath = "\(path).tmp.\(UUID().uuidString)"
        do {
            try desired.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
            if FileManager.default.fileExists(atPath: path) {
                _ = try? FileManager.default.removeItem(atPath: path)
            }
            try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
        } catch {
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw SeedError.ioFailure(path: path, underlying: String(describing: error))
        }
    }

    /// Returns the rendered `config.yaml` for a tenant.
    /// - Parameter defaultModel: the model alias served by `/v1/chat/completions`.
    /// - Parameter mnemosyneEnabled: gates the Mnemosyne memory block. See `seed`.
    static func configYAML(
        defaultModel: String,
        mnemosyneEnabled: Bool,
        audioProxy: HermesAudioProxySeed?
    ) -> String {
        let baseConfig = """
        # Auto-generated by HermesContainerManager (HER-254). Do not edit in-place;
        # changes are overwritten on container restart unless the SHA-256 matches.

        model:
          default: "\(defaultModel)"

        platforms:
          api_server:
            enabled: true
            host: 0.0.0.0
            port: 8642

        # Messaging gateways (telegram/discord/slack/…) are NOT listed here:
        # activation is driven by the presence of each platform's token env-var
        # in `.env` (see HermesGatewayCatalog.envVars). Listing them with
        # `enabled: false` is inert for messaging and only risks confusion.

        # Access is restricted per-gateway via each platform's *_ALLOWED_USERS
        # env-var (seeded from the owner's IDs). NOT open: allow_all_users stays
        # false (and is inert anyway — `gateway run` reads GATEWAY_ALLOW_ALL_USERS
        # from .env, which we deliberately do NOT set).
        gateway:
          allow_all_users: false

        logging:
          level: INFO
        """

        // Speech. `provider:` is mandatory in BOTH blocks, and neither
        // default is safe for us:
        //
        //   - stt defaults to `local` (faster-whisper), which is not in the
        //     image, so voice notes would fail outright.
        //   - tts defaults to `edge` — free, keyless, and outside every
        //     control here. Worse, `tts_tool` treats *any* unrecognised
        //     provider name as Edge TTS (see its final `else` branch), so
        //     "disabling" TTS by writing a placeholder name silently enables
        //     the unmetered path instead. Pinning `openai` at our proxy is
        //     the only way to be sure synthesis cannot happen off-budget.
        //
        // Until the speech route ships, `/v1/audio/speech` answers 501, so a
        // user who turns on `/voice` gets a clear refusal rather than an
        // unbilled voice note.
        let base = audioProxy.map { proxy in
            baseConfig + """


        stt:
          enabled: true
          echo_transcripts: true
          provider: openai
          openai:
            base_url: "\(proxy.baseURL)"
            model: "\(proxy.sttModel)"

        tts:
          provider: openai
          openai:
            base_url: "\(proxy.baseURL)"
            model: "\(proxy.ttsModel)"
            voice: "\(proxy.ttsVoice)"
        """
        } ?? baseConfig

        guard mnemosyneEnabled else {
            // Mnemosyne off: emit neither the MCP block nor the native-memory
            // override. Hermes keeps its built-in MEMORY.md/USER.md memory.
            return base
        }

        // Mnemosyne on (managed default). Two coordinated changes:
        //
        //   1. Disable Hermes' native persistent memory (the `memory:` block —
        //      curated MEMORY.md/USER.md injected into the system prompt every
        //      session). Without this, two memory systems compete; the decision
        //      is Mnemosyne-only. Keys are the stable top-level `memory:` block
        //      from the base image's cli-config.yaml.example (NOT the deprecated
        //      `toolsets` key). `session_search` is intentionally left alone —
        //      it's conversation recall, not a competing long-term store.
        //
        //   2. Register Mnemosyne as a Hermes MCP server. `mcp_servers:` is the
        //      top-level key this Hermes build reads (see cli-config.yaml.example).
        //      Hermes spawns `mnemosyne mcp` (stdio) and auto-discovers its
        //      remember/recall/triples tools. The `mnemosyne` console script is
        //      baked into the image (docker/hermes.Dockerfile). The per-server
        //      `env:` is required: Hermes passes ONLY these (plus safe defaults)
        //      to the subprocess, so MNEMOSYNE_DATA_DIR must be set here to land
        //      the SQLite store on the persisted /opt/data volume.
        //
        // `seed()`'s SHA-256 drift rewrite back-fills existing tenants on next
        // restart when this toggle flips.
        return base + """


        # HER-XXX — Mnemosyne is the default memory layer: disable Hermes' native
        # curated memory so Mnemosyne (below) is the single source of truth.
        memory:
          memory_enabled: false
          user_profile_enabled: false

        # HER-XXX — Mnemosyne memory, wired as a Hermes MCP server.
        mcp_servers:
          mnemosyne:
            command: mnemosyne
            args: ["mcp"]
            env:
              MNEMOSYNE_DATA_DIR: /opt/data/mnemosyne
              FASTEMBED_CACHE_PATH: /opt/data/mnemosyne/cache
        """
    }

    /// Returns the rendered `.env`: the `API_SERVER_*` block plus one line per
    /// configured gateway token env-var. Activating a messaging platform is as
    /// simple as its token env-var being present here.
    static func envFile(
        apiKey: String,
        gateways: [HermesGatewaySeed] = [],
        audioProxy: HermesAudioProxySeed?
    ) -> String {
        var lines = [
            "# Auto-generated by HermesContainerManager (HER-254).",
            "API_SERVER_KEY=\(apiKey)",
            "API_SERVER_ENABLED=true",
            "API_SERVER_HOST=0.0.0.0",
            "API_SERVER_PORT=8642",
        ]
        // Deterministic order (sorted by env-var name) so the SHA-256 drift
        // check is stable across restarts.
        var gatewayVars: [String: String] = [:]
        for gw in gateways {
            for (k, v) in HermesGatewayCatalog.envVars(gw.gatewayID, config: gw.config) {
                gatewayVars[k] = v
            }
        }
        if !gatewayVars.isEmpty {
            lines.append("")
            lines.append("# Messaging gateways (token presence activates the platform).")
            for key in gatewayVars.keys.sorted() {
                lines.append("\(key)=\(envQuote(gatewayVars[key]!))")
            }
        }
        if let audioProxy {
            lines.append("")
            lines.append("# Speech credentials for the LuminaVault audio proxy.")
            // VOICE_TOOLS_OPENAI_KEY, not OPENAI_API_KEY: this credential is
            // scoped to `/v1/audio/*` and must not be picked up as a general
            // chat provider key.
            lines.append("VOICE_TOOLS_OPENAI_KEY=\(envQuote(audioProxy.token))")
            // Belt-and-braces alongside `stt.openai.base_url` in config.yaml.
            // Older Hermes builds ignore the config value on the env-key path
            // and read only this; setting both means a container on either
            // build reaches the proxy rather than api.openai.com.
            lines.append("STT_OPENAI_BASE_URL=\(envQuote(audioProxy.baseURL))")
        }
        return lines.joined(separator: "\n")
    }

    /// Single-quote a `.env` value so python-dotenv treats it literally (no
    /// `${VAR}` interpolation, no backslash-escape processing). Gateway tokens
    /// are single-quote-free; any embedded `'` is stripped defensively rather
    /// than producing a malformed line.
    private static func envQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: ""))'"
    }
}
