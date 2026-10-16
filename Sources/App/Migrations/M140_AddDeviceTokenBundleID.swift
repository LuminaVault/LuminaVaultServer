import FluentKit
import SQLKit

/// The app a device token was issued for (`com.lumina.fernando`,
/// `com.lumina.fernando.beta`, …). APNs only delivers a token to the topic it
/// was issued under, so the push service sends each device to its own app's
/// id. Nullable: every existing token predates it and falls back to the
/// configured `apns.bundleId`.
struct M140_AddDeviceTokenBundleID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("ALTER TABLE device_tokens ADD COLUMN IF NOT EXISTS bundle_id TEXT").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("device_tokens")
            .deleteField("bundle_id")
            .update()
    }
}

private enum MigrationError: Error { case requiresSQL }
