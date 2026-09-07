import FluentKit
import SQLKit

/// M122 — records whether a user's provider endpoint actually honours tool
/// calls.
///
/// A credential that authenticates is not the same as an endpoint that works.
/// An OpenAI-compatible gateway can accept a request carrying `tools`, ignore
/// the block entirely, and answer the question from the model's own
/// knowledge. The response is a well-formed 200 with plausible content, so
/// nothing upstream notices — and the product then tells the user their
/// skills and workflows are running when the model never called a single
/// tool.
///
/// Three-valued on purpose, hence a nullable boolean rather than `NOT NULL
/// DEFAULT false`:
///
/// - `true`  — the probe saw a tool call.
/// - `false` — the probe ran and the endpoint answered without calling.
/// - `NULL`  — not probed, or the probe could not reach a verdict.
///
/// NULL must read as *permissive*. The probe is a best-effort background
/// check against a third party; treating "we do not know" as "no tools" would
/// disable working setups on a network blip, which is a worse failure than
/// the one being detected.
struct M122_AddProviderToolSupport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        ALTER TABLE user_provider_credentials
            ADD COLUMN IF NOT EXISTS supports_tools BOOLEAN,
            ADD COLUMN IF NOT EXISTS tools_probed_at TIMESTAMPTZ;
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        ALTER TABLE user_provider_credentials
            DROP COLUMN IF EXISTS supports_tools,
            DROP COLUMN IF EXISTS tools_probed_at;
        """#, on: sql)
    }
}
