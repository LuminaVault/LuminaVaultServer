import FluentKit
import SQLKit

/// HER-204 — adds `chars_out` column to `usage_meter` for TTS character
/// metering. POST `/v1/tts` is billed by characters synthesised; the new
/// column lives alongside the existing token columns so the same
/// `(tenant_id, day, model)` row aggregates both metric types and the
/// cost dashboard query keeps working unchanged.
///
/// Safe online migration: `DEFAULT 0` means no backfill required.
struct M35_AddUsageMeterCharsOut: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M35Error.requiresSQL
        }
        try await sql.raw(
            "ALTER TABLE usage_meter ADD COLUMN IF NOT EXISTS chars_out BIGINT NOT NULL DEFAULT 0",
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M35Error.requiresSQL
        }
        try await sql.raw("ALTER TABLE usage_meter DROP COLUMN IF EXISTS chars_out").run()
    }
}

private enum M35Error: Error { case requiresSQL }
