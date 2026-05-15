import FluentKit
import SQLKit

/// HER-207 — adds nullable geo columns to `memories` so Apple Maps
/// location-anchored captures (HER-114) preserve radius / bounding-box
/// query semantics. Stashing geo in `tags` would have worked for v0 but
/// would lose those queries forever.
///
/// Columns:
/// - `lat` `double precision` — latitude in degrees (WGS84). NULL when
///   the capture had no associated location.
/// - `lng` `double precision` — longitude in degrees (WGS84).
/// - `accuracy_m` `double precision` — radius of the GPS fix in metres;
///   client-supplied, typically from CoreLocation horizontal accuracy.
/// - `place_name` `text` — reverse-geocoded human label (e.g.
///   "Café A Brasileira, Lisbon"), client-supplied via MapKit.
///
/// All four are independently nullable but clients SHOULD set either
/// all four or none. Backfill: all existing rows stay NULL; behaviour
/// for non-geo memories is unchanged.
///
/// No geospatial index — Haversine `WHERE` is fine until query workload
/// justifies pgvector / PostGIS. Idempotent via `ADD COLUMN IF NOT EXISTS`.
struct M36_AddMemoryGeo: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M36Error.requiresSQL
        }
        try await sql.raw("ALTER TABLE memories ADD COLUMN IF NOT EXISTS lat DOUBLE PRECISION").run()
        try await sql.raw("ALTER TABLE memories ADD COLUMN IF NOT EXISTS lng DOUBLE PRECISION").run()
        try await sql.raw("ALTER TABLE memories ADD COLUMN IF NOT EXISTS accuracy_m DOUBLE PRECISION").run()
        try await sql.raw("ALTER TABLE memories ADD COLUMN IF NOT EXISTS place_name TEXT").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M36Error.requiresSQL
        }
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS place_name").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS accuracy_m").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS lng").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS lat").run()
    }
}

private enum M36Error: Error { case requiresSQL }
