import FluentKit
import SQLKit

/// Muse Chat stage C — the last device location fix, per tenant.
///
/// A 07:00 weather job runs while the phone is usually asleep, so the live
/// device read (`location_recent`) often cannot answer. Whenever a live read
/// does succeed the server keeps that one fix here and the weather tool falls
/// back to it. One row's worth of columns, overwritten each time — this is
/// not a location history. `DELETE /v1/me/location` clears it, and it is only
/// ever used while the tenant's Location consent is on.
///
/// All nullable; `NULL` means nothing is cached.
struct M136_AddUserLastLocation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE users
            ADD COLUMN IF NOT EXISTS last_location_lat DOUBLE PRECISION NULL,
            ADD COLUMN IF NOT EXISTS last_location_lng DOUBLE PRECISION NULL,
            ADD COLUMN IF NOT EXISTS last_location_place TEXT NULL,
            ADD COLUMN IF NOT EXISTS last_location_at TIMESTAMPTZ NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE users
            DROP COLUMN IF EXISTS last_location_at,
            DROP COLUMN IF EXISTS last_location_place,
            DROP COLUMN IF EXISTS last_location_lng,
            DROP COLUMN IF EXISTS last_location_lat
        """).run()
    }
}
