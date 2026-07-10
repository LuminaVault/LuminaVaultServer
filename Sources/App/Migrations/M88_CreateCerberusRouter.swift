import FluentKit
import SQLKit

/// Cerberus Router profiles, scoped bindings, prompt-free execution telemetry,
/// and durable monthly aggregates. Profile rules are a revisioned JSONB
/// document so a visual-editor save is atomic.
struct M88_CreateCerberusRouter: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS router_profiles (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            mode TEXT NOT NULL,
            is_preset BOOLEAN NOT NULL DEFAULT FALSE,
            document JSONB NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, name)
        );
        CREATE INDEX IF NOT EXISTS router_profiles_tenant_idx ON router_profiles(tenant_id);

        CREATE TABLE IF NOT EXISTS router_bindings (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            scope TEXT NOT NULL,
            scope_id TEXT NOT NULL,
            profile_id UUID NOT NULL REFERENCES router_profiles(id) ON DELETE CASCADE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, scope, scope_id)
        );
        CREATE INDEX IF NOT EXISTS router_bindings_profile_idx ON router_bindings(profile_id);

        CREATE TABLE IF NOT EXISTS router_executions (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            profile_id UUID REFERENCES router_profiles(id) ON DELETE SET NULL,
            rule_id UUID,
            surface TEXT NOT NULL,
            task_type TEXT NOT NULL,
            strategy TEXT NOT NULL,
            status TEXT NOT NULL,
            selected_provider TEXT,
            selected_model TEXT,
            tokens_in BIGINT NOT NULL DEFAULT 0,
            tokens_out BIGINT NOT NULL DEFAULT 0,
            estimated_cost_usd_micros BIGINT NOT NULL DEFAULT 0,
            latency_ms BIGINT NOT NULL DEFAULT 0,
            usage_estimated BOOLEAN NOT NULL DEFAULT TRUE,
            fallback_count INTEGER NOT NULL DEFAULT 0,
            occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS router_executions_tenant_time_idx
            ON router_executions(tenant_id, occurred_at DESC);

        CREATE TABLE IF NOT EXISTS router_attempts (
            id UUID PRIMARY KEY,
            execution_id UUID NOT NULL REFERENCES router_executions(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            role TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            outcome TEXT NOT NULL,
            error_code TEXT,
            tokens_in BIGINT NOT NULL DEFAULT 0,
            tokens_out BIGINT NOT NULL DEFAULT 0,
            estimated_cost_usd_micros BIGINT NOT NULL DEFAULT 0,
            latency_ms BIGINT NOT NULL DEFAULT 0,
            usage_estimated BOOLEAN NOT NULL DEFAULT TRUE,
            occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS router_attempts_execution_idx ON router_attempts(execution_id, ordinal);

        CREATE TABLE IF NOT EXISTS router_monthly_usage (
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            month DATE NOT NULL,
            managed_usd_micros BIGINT NOT NULL DEFAULT 0,
            byok_usd_micros BIGINT NOT NULL DEFAULT 0,
            reserved_usd_micros BIGINT NOT NULL DEFAULT 0,
            requests BIGINT NOT NULL DEFAULT 0,
            successful_requests BIGINT NOT NULL DEFAULT 0,
            fallback_count BIGINT NOT NULL DEFAULT 0,
            tokens_in BIGINT NOT NULL DEFAULT 0,
            tokens_out BIGINT NOT NULL DEFAULT 0,
            latency_ms_total BIGINT NOT NULL DEFAULT 0,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (tenant_id, month)
        );
        """#).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        DROP TABLE IF EXISTS router_monthly_usage;
        DROP TABLE IF EXISTS router_attempts;
        DROP TABLE IF EXISTS router_executions;
        DROP TABLE IF EXISTS router_bindings;
        DROP TABLE IF EXISTS router_profiles;
        """#).run()
    }
}
