import FluentKit
import SQLKit

/// M126 — let `usage_events` carry voice metrics.
///
/// M65 created the table with a CHECK pinning `metric` to the two memory
/// compile values. Adding a third writer means widening that constraint;
/// without it every voice row fails the insert, and because the store
/// swallows its own errors the failure would be silent — metering that
/// looks configured and records nothing.
///
/// `voice_speech` is included ahead of its writer. `POST /v1/audio/speech`
/// currently returns 501; when the TTS adapter lands it should not need a
/// migration to start metering, and an unused enum value costs nothing.
///
/// Additive: no backfill, no data touched. The old values stay valid.
struct M126_AddVoiceUsageMetrics: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M126Error.requiresSQL
        }

        // Postgres names a column-level CHECK `<table>_<column>_check`, which
        // is what M65's inline `CHECK (metric IN (...))` produced.
        try await sql.raw(#"ALTER TABLE usage_events DROP CONSTRAINT IF EXISTS usage_events_metric_check"#).run()
        try await sql.raw(#"""
        ALTER TABLE usage_events ADD CONSTRAINT usage_events_metric_check
        CHECK (metric IN ('memory_compile_run', 'memory_compile_file', 'voice_transcribe', 'voice_speech'))
        """#).run()

        // The voice dashboards all slice by metric over a time range, and the
        // M65 indexes are tenant-first — fine for "what did this user do",
        // useless for "what did Telegram voice do across the estate".
        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS usage_events_metric_occurred_idx ON usage_events(metric, occurred_at DESC)"#
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M126Error.requiresSQL
        }

        // Rows written under the new values would violate the narrowed
        // constraint, so they go first. Reverting this migration means
        // abandoning voice metering — deleting its rows is the honest
        // interpretation, and leaving them would make the revert fail.
        try await sql.raw(
            #"DELETE FROM usage_events WHERE metric IN ('voice_transcribe', 'voice_speech')"#
        ).run()
        try await sql.raw(#"DROP INDEX IF EXISTS usage_events_metric_occurred_idx"#).run()
        try await sql.raw(#"ALTER TABLE usage_events DROP CONSTRAINT IF EXISTS usage_events_metric_check"#).run()
        try await sql.raw(#"""
        ALTER TABLE usage_events ADD CONSTRAINT usage_events_metric_check
        CHECK (metric IN ('memory_compile_run', 'memory_compile_file'))
        """#).run()
    }
}

private enum M126Error: Error { case requiresSQL }
