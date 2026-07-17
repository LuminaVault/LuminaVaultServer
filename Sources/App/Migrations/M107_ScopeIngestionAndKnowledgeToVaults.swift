import FluentKit
import SQLKit

struct M107_ScopeIngestionAndKnowledgeToVaults: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for table in [
            "knowledge_nodes",
            "knowledge_edges",
            "knowledge_evidence",
            "knowledge_extraction_jobs",
            "ingestion_batches",
            "ingestion_items",
            "ingestion_events",
        ] {
            try await repointTenantForeignKey(table: table, on: sql)
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for table in [
            "ingestion_events",
            "ingestion_items",
            "ingestion_batches",
            "knowledge_extraction_jobs",
            "knowledge_evidence",
            "knowledge_edges",
            "knowledge_nodes",
        ] {
            try await dropVaultTenantForeignKey(table: table, on: sql)
        }
    }

    private func repointTenantForeignKey(table: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
        DO $$
        DECLARE constraint_name TEXT;
        BEGIN
            SELECT c.conname INTO constraint_name
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_class target ON target.oid = c.confrelid
            WHERE t.relname = '\(unsafeRaw: table)' AND target.relname = 'users' AND c.contype = 'f'
              AND EXISTS (
                SELECT 1 FROM unnest(c.conkey) key
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = key
                WHERE a.attname = 'tenant_id'
              )
            LIMIT 1;
            IF constraint_name IS NOT NULL THEN
                EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', '\(unsafeRaw: table)', constraint_name);
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON t.oid = c.conrelid
                JOIN pg_class target ON target.oid = c.confrelid
                WHERE t.relname = '\(unsafeRaw: table)' AND target.relname = 'vaults' AND c.contype = 'f'
                  AND EXISTS (
                    SELECT 1 FROM unnest(c.conkey) key
                    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = key
                    WHERE a.attname = 'tenant_id'
                  )
            ) THEN
                EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (tenant_id) REFERENCES vaults(id) ON DELETE CASCADE',
                               '\(unsafeRaw: table)', '\(unsafeRaw: table)_tenant_vault_fk');
            END IF;
        END $$
        """).run()
    }

    private func dropVaultTenantForeignKey(table: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
        DO $$
        DECLARE constraint_name TEXT;
        BEGIN
            SELECT c.conname INTO constraint_name
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_class target ON target.oid = c.confrelid
            WHERE t.relname = '\(unsafeRaw: table)' AND target.relname = 'vaults' AND c.contype = 'f'
              AND EXISTS (
                SELECT 1 FROM unnest(c.conkey) key
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = key
                WHERE a.attname = 'tenant_id'
              )
            LIMIT 1;
            IF constraint_name IS NOT NULL THEN
                EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', '\(unsafeRaw: table)', constraint_name);
            END IF;
        END $$
        """).run()
    }
}
