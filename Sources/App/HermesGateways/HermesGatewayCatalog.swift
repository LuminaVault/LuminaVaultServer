import Foundation
import LuminaVaultShared

/// HER-241 — static catalog of supported Hermes messaging gateways and
/// the fields each one needs to be configured.
///
/// The list mirrors what `hermes gateway setup <id>` accepts upstream
/// (Telegram, Discord, Slack, WhatsApp). Per-field metadata (kind,
/// label, placeholder) is served to the client so the iOS form can
/// render dynamically without hardcoding gateway shapes.
///
/// When Hermes ships per-gateway HTTP introspection, this catalog
/// becomes the fallback for clients that can't reach Hermes directly;
/// the controller can merge the upstream report into the static rows.
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
                    key: "application_id",
                    label: "Application ID",
                    placeholder: "1234567890",
                    kind: .text,
                    isRequired: true,
                ),
            ],
        ),
        .slack: Entry(
            displayName: "Slack",
            iconSlug: "slack",
            description: "Pipe Lumina into a Slack workspace via your Slack app.",
            requiredFields: [
                HermesGatewayField(
                    key: "bot_token",
                    label: "Bot token (xoxb-…)",
                    placeholder: "xoxb-…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "signing_secret",
                    label: "Signing secret",
                    placeholder: "8f7…",
                    kind: .secret,
                    isRequired: true,
                ),
            ],
        ),
        .whatsapp: Entry(
            displayName: "WhatsApp",
            iconSlug: "whatsapp",
            description: "Reach Lumina from WhatsApp via a Cloud API number.",
            requiredFields: [
                HermesGatewayField(
                    key: "phone_number_id",
                    label: "Phone number ID",
                    placeholder: "10\u{200B}9876543210",
                    kind: .text,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "access_token",
                    label: "Access token",
                    placeholder: "EAAG…",
                    kind: .secret,
                    isRequired: true,
                ),
                HermesGatewayField(
                    key: "verify_token",
                    label: "Webhook verify token",
                    placeholder: "user-defined string",
                    kind: .text,
                    isRequired: true,
                ),
            ],
        ),
    ]

    struct Entry: Sendable {
        let displayName: String
        let iconSlug: String
        let description: String
        let requiredFields: [HermesGatewayField]
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
