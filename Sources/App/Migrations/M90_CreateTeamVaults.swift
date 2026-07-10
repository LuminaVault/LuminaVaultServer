import FluentKit
import SQLKit

struct M90_CreateTeamVaults: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS teams (
            id UUID PRIMARY KEY,
            name TEXT NOT NULL,
            owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
            billing_sponsor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
            archived_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS vaults (
            id UUID PRIMARY KEY,
            team_id UUID REFERENCES teams(id) ON DELETE CASCADE,
            personal_owner_user_id UUID REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            archived_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ,
            CONSTRAINT vault_owner_kind CHECK (
                (team_id IS NOT NULL AND personal_owner_user_id IS NULL) OR
                (team_id IS NULL AND personal_owner_user_id IS NOT NULL)
            )
        )
        """).run()
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS idx_vaults_personal_owner ON vaults(personal_owner_user_id) WHERE personal_owner_user_id IS NOT NULL").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_vaults_team ON vaults(team_id)").run()

        try await sql.raw("""
        INSERT INTO vaults (id, personal_owner_user_id, name, created_at, updated_at)
        SELECT id, id, username || '''s Vault', created_at, updated_at FROM users
        ON CONFLICT (id) DO NOTHING
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS team_memberships (
            id UUID PRIMARY KEY,
            team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
            created_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ,
            UNIQUE(team_id, user_id)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS vault_memberships (
            id UUID PRIMARY KEY,
            vault_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            role TEXT NOT NULL CHECK (role IN ('viewer', 'editor', 'admin')),
            can_use_ai BOOLEAN NOT NULL DEFAULT FALSE,
            created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
            created_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ,
            UNIQUE(vault_id, user_id)
        )
        """).run()
        try await sql.raw("""
        INSERT INTO vault_memberships
            (id, vault_id, user_id, role, can_use_ai, created_by_user_id, created_at, updated_at)
        SELECT gen_random_uuid(), id, id, 'admin', TRUE, id, NOW(), NOW() FROM users
        ON CONFLICT (vault_id, user_id) DO NOTHING
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS team_invitations (
            id UUID PRIMARY KEY,
            team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
            email TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            vault_grants TEXT NOT NULL,
            invited_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
            expires_at TIMESTAMPTZ NOT NULL,
            accepted_at TIMESTAMPTZ,
            revoked_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_team_invitations_email ON team_invitations(lower(email))").run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS vault_activity_events (
            id UUID PRIMARY KEY,
            vault_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
            actor_name TEXT NOT NULL,
            action TEXT NOT NULL,
            target_type TEXT NOT NULL,
            target_id UUID,
            target_title TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_vault_activity_cursor ON vault_activity_events(vault_id, created_at DESC, id DESC)").run()

        // Existing personal rows retain the same UUID. Repoint only the
        // knowledge/orchestration tables; identity and personal integrations
        // deliberately continue to reference users.
        for table in [
            "spaces", "vault_files", "memories", "memories_archive",
            "kb_compile_reject_list", "kanban_boards", "kanban_columns", "kanban_cards",
        ] {
            try await repointTenantForeignKey(table: table, on: sql)
        }

        for table in ["spaces", "vault_files", "memories", "kanban_boards", "kanban_cards"] {
            try await sql.raw("ALTER TABLE \(unsafeRaw: table) ADD COLUMN IF NOT EXISTS created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: table) ADD COLUMN IF NOT EXISTS updated_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL").run()
            try await sql.raw("UPDATE \(unsafeRaw: table) SET created_by_user_id = tenant_id WHERE created_by_user_id IS NULL").run()
            try await sql.raw("UPDATE \(unsafeRaw: table) SET updated_by_user_id = created_by_user_id WHERE updated_by_user_id IS NULL").run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for table in ["spaces", "vault_files", "memories", "kanban_boards", "kanban_cards"] {
            try await sql.raw("ALTER TABLE \(unsafeRaw: table) DROP COLUMN IF EXISTS updated_by_user_id").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: table) DROP COLUMN IF EXISTS created_by_user_id").run()
        }
        try await sql.raw("DROP TABLE IF EXISTS vault_activity_events").run()
        try await sql.raw("DROP TABLE IF EXISTS team_invitations").run()
        try await sql.raw("DROP TABLE IF EXISTS vault_memberships").run()
        try await sql.raw("DROP TABLE IF EXISTS team_memberships").run()
        try await sql.raw("DROP TABLE IF EXISTS vaults").run()
        try await sql.raw("DROP TABLE IF EXISTS teams").run()
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
            ) THEN
                EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (tenant_id) REFERENCES vaults(id) ON DELETE CASCADE',
                               '\(unsafeRaw: table)', '\(unsafeRaw: table)_tenant_vault_fk');
            END IF;
        END $$
        """).run()
    }
}
