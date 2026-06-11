import FluentKit
import SQLKit

/// HER-176 — opt-out flag that excludes models with CN-origin weights
/// (DeepSeek, Qwen, Kimi) from `ModelRouter.pick`, regardless of whether
/// inference is hosted in the US (Together / Groq / Fireworks / DeepInfra).
///
/// Default `false`: full routing matrix available; cheapest path wins.
/// `true`: ModelRouter falls back to higher-cost US/EU-origin models (Gemini
/// Flash → GPT-5-mini → …). Documented trade-off in `docs/llm-models.md` and
/// in the iOS Settings UI copy ("Higher cost; toggle off to enable
/// Chinese-weight models via US-hosted inference").
struct M25_AddUserPrivacyNoCNOrigin: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_no_cn_origin BOOLEAN NOT NULL DEFAULT FALSE"#
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"ALTER TABLE users DROP COLUMN IF EXISTS privacy_no_cn_origin"#).run()
    }
}
