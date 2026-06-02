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
