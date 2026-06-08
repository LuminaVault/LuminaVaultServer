import Foundation
import LuminaVaultShared

/// HER-241 — static catalog of supported Hermes messaging gateways and
/// the fields each one needs to be configured.
///
/// Field shapes are verified against the real Hermes image's
/// `hermes_cli/gateway.py` `_PLATFORMS` registry (see the
/// `hermes-gateway-env-schema` memory): activation is driven by the
/// presence of each gateway's token **env-var** in the container's
/// `.env`, not by a `config.yaml` block. `envVars(_:config:)` maps the
/// catalog's field keys to those env-var names for the actuation flow.
///
/// WhatsApp is special: it has no enterable credential — it pairs via the
/// interactive `hermes whatsapp` QR flow. It is surfaced here with
/// `pairingKind: .whatsappQR` and **no** `requiredFields`, so the client
/// routes it to the QR-pairing screen instead of a credential form. Its
/// `envVars`/`validate` paths intentionally produce nothing; the credential
/// routes (PUT/test) reject pairing gateways. See `WhatsAppPairingService`.
enum HermesGatewayCatalog {
    static let entries: [HermesGatewayID: Entry] = [
        .telegram: Entry(
            displayName: "Telegram",
            iconSlug: "telegram",
            description: "Chat with Lumina from Telegram via a bot you control.",
            requiredFields: [
                HermesGatewayField(
                    key: "bot_token",
                    label: "Bot token",
                    placeholder: "123456:ABC-DEF…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Your Telegram user ID(s)",
                    placeholder: "476978568 (from @userinfobot)",
                    kind: .text,
                    isRequired: true,
                ),
            ],
        ),
        .discord: Entry(
            displayName: "Discord",
            iconSlug: "discord",
            description: "Connect Lumina to a private Discord server.",
            requiredFields: [
                HermesGatewayField(
                    key: "bot_token",
                    label: "Bot token",
                    placeholder: "MTE3…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Your Discord user ID(s)",
                    placeholder: "184264928281100288",
                    kind: .text,
                    isRequired: true,
                ),
            ],
        ),
        .slack: Entry(
            displayName: "Slack",
            iconSlug: "slack",
            description: "Pipe Lumina into a Slack workspace via your Slack app (Socket Mode).",
            requiredFields: [
                HermesGatewayField(
                    key: "bot_token",
                    label: "Bot token (xoxb-…)",
                    placeholder: "xoxb-…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "app_token",
                    label: "App token (xapp-…)",
                    placeholder: "xapp-…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Your Slack member ID(s)",
                    placeholder: "U01234567",
                    kind: .text,
                    isRequired: true,
                ),
            ],
        ),
        .email: Entry(
            displayName: "Email",
            iconSlug: "email",
            description: "Send and receive email as Lumina over IMAP/SMTP.",
            requiredFields: [
                HermesGatewayField(
                    key: "address",
                    label: "Email address",
                    placeholder: "lumina@gmail.com",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "password",
                    label: "Password (or app password)",
                    placeholder: "app password",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "imap_host",
                    label: "IMAP host",
                    placeholder: "imap.gmail.com",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "smtp_host",
                    label: "SMTP host",
                    placeholder: "smtp.gmail.com",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Allowed senders (comma-separated)",
                    placeholder: "you@email.com",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "imap_port",
                    label: "IMAP port",
                    placeholder: "993",
                    kind: .text,
                    isRequired: false,
                ),
                HermesGatewayField(
                    key: "smtp_port",
                    label: "SMTP port",
                    placeholder: "587",
                    kind: .text,
                    isRequired: false,
                ),
                HermesGatewayField(
                    key: "home_address",
                    label: "Home address (cron delivery)",
                    placeholder: "you@email.com",
                    kind: .text,
                    isRequired: false,
                ),
            ],
        ),
        .matrix: Entry(
            displayName: "Matrix",
            iconSlug: "matrix",
            description: "Chat with Lumina over Matrix — your own homeserver or a public one like matrix.org.",
            requiredFields: [
                HermesGatewayField(
                    key: "homeserver",
                    label: "Homeserver URL",
                    placeholder: "https://matrix.org",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "access_token",
                    label: "Access token",
                    placeholder: "syt_…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Allowed user ID(s)",
                    placeholder: "@you:matrix.org",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "user_id",
                    label: "Bot user ID (optional)",
                    placeholder: "@lumina:matrix.org",
                    kind: .text,
                    isRequired: false,
                ),
            ],
        ),
        .ntfy: Entry(
            displayName: "ntfy",
            iconSlug: "ntfy",
            description: "Push-chat with Lumina via ntfy.sh (or a self-hosted server) — a topic is all you need.",
            requiredFields: [
                HermesGatewayField(
                    key: "topic",
                    label: "Topic",
                    placeholder: "lumina-yourname-2026",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Allowed topic(s)",
                    placeholder: "lumina-yourname-2026",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "server_url",
                    label: "Server URL (optional)",
                    placeholder: "https://ntfy.sh",
                    kind: .text,
                    isRequired: false,
                ),
                HermesGatewayField(
                    key: "token",
                    label: "Token (optional)",
                    placeholder: "tk_…",
                    kind: .secret,
                    isRequired: false,
                ),
            ],
        ),
        .mattermost: Entry(
            displayName: "Mattermost",
            iconSlug: "mattermost",
            description: "Connect Lumina to a Mattermost workspace via a bot account (outbound WebSocket).",
            requiredFields: [
                HermesGatewayField(
                    key: "url",
                    label: "Server URL",
                    placeholder: "https://mm.example.com",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "token",
                    label: "Bot token",
                    placeholder: "bot account access token",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "allowed_users",
                    label: "Allowed user ID(s)",
                    placeholder: "3uo8dkh1p7g1mfk49ear5fzs5c",
                    kind: .text,
                    isRequired: true,
                ),
            ],
        ),
        .whatsapp: Entry(
            displayName: "WhatsApp",
            iconSlug: "whatsapp",
            description: "Chat with Lumina on WhatsApp. Pairs by scanning a QR with your phone — no token to enter.",
            requiredFields: [],
            pairingKind: .whatsappQR,
        ),
    ]

    /// Maps a gateway's saved field config to the Hermes `.env` env-vars that
    /// activate it (`hermes_cli/gateway.py` `_PLATFORMS`). Only keys with a
    /// non-empty value are emitted. Unknown gateways return `[:]`.
    static func envVars(_ id: HermesGatewayID, config: [String: String]) -> [String: String] {
        func value(_ key: String) -> String? {
            guard let v = config[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return nil }
            return v
        }
        var out: [String: String] = [:]
        switch id {
        case .telegram:
            if let t = value("bot_token") { out["TELEGRAM_BOT_TOKEN"] = t }
            if let u = value("allowed_users") { out["TELEGRAM_ALLOWED_USERS"] = u }
        case .discord:
            if let t = value("bot_token") { out["DISCORD_BOT_TOKEN"] = t }
            if let u = value("allowed_users") { out["DISCORD_ALLOWED_USERS"] = u }
        case .slack:
            if let t = value("bot_token") { out["SLACK_BOT_TOKEN"] = t }
            if let t = value("app_token") { out["SLACK_APP_TOKEN"] = t }
            if let u = value("allowed_users") { out["SLACK_ALLOWED_USERS"] = u }
        case .whatsapp:
            // Not remotely configurable (interactive QR pairing). No env-vars.
            break
        case .email:
            if let t = value("address") { out["EMAIL_ADDRESS"] = t }
            if let t = value("password") { out["EMAIL_PASSWORD"] = t }
            if let t = value("imap_host") { out["EMAIL_IMAP_HOST"] = t }
            if let t = value("smtp_host") { out["EMAIL_SMTP_HOST"] = t }
            if let t = value("allowed_users") { out["EMAIL_ALLOWED_USERS"] = t }
            if let t = value("imap_port") { out["EMAIL_IMAP_PORT"] = t }
            if let t = value("smtp_port") { out["EMAIL_SMTP_PORT"] = t }
            if let t = value("home_address") { out["EMAIL_HOME_ADDRESS"] = t }
        case .matrix:
            if let t = value("homeserver") { out["MATRIX_HOMESERVER"] = t }
            if let t = value("access_token") { out["MATRIX_ACCESS_TOKEN"] = t }
            if let u = value("allowed_users") { out["MATRIX_ALLOWED_USERS"] = u }
            if let t = value("user_id") { out["MATRIX_USER_ID"] = t }
        case .ntfy:
            if let t = value("topic") { out["NTFY_TOPIC"] = t }
            if let u = value("allowed_users") { out["NTFY_ALLOWED_USERS"] = u }
            if let t = value("server_url") { out["NTFY_SERVER_URL"] = t }
            if let t = value("token") { out["NTFY_TOKEN"] = t }
        case .mattermost:
            if let t = value("url") { out["MATTERMOST_URL"] = t }
            if let t = value("token") { out["MATTERMOST_TOKEN"] = t }
            if let u = value("allowed_users") { out["MATTERMOST_ALLOWED_USERS"] = u }
        }
        return out
    }

    struct Entry {
        let displayName: String
        let iconSlug: String
        let description: String
        let requiredFields: [HermesGatewayField]
        /// Non-nil → interactive pairing gateway (WhatsApp). Credential
        /// gateways leave this `nil`.
        var pairingKind: HermesGatewayPairingKind?

        init(
            displayName: String,
            iconSlug: String,
            description: String,
            requiredFields: [HermesGatewayField],
            pairingKind: HermesGatewayPairingKind? = nil,
        ) {
            self.displayName = displayName
            self.iconSlug = iconSlug
            self.description = description
            self.requiredFields = requiredFields
            self.pairingKind = pairingKind
        }
    }

    static func entry(for id: HermesGatewayID) -> Entry {
        // All HermesGatewayID cases must be present in `entries`. Any
        // missing case is a programmer error caught by the unit test;
        // the force-unwrap here keeps the call-site clean.
        entries[id]!
    }

    /// Validate a PUT body against the catalog: every `isRequired`
    /// field must be present and non-empty. Returns the offending key
    /// on failure for stable error codes.
    static func validate(_ id: HermesGatewayID, config: [String: String]) -> ValidationResult {
        let fields = entry(for: id).requiredFields
        for field in fields where field.isRequired {
            let value = config[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == nil || value!.isEmpty {
                return .missing(field.key)
            }
        }
        return .ok
    }

    enum ValidationResult: Equatable {
        case ok
        case missing(String)
    }
}
