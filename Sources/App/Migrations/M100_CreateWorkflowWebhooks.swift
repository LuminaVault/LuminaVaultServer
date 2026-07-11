import FluentKit
import SQLKit

struct M100_CreateWorkflowWebhooks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS workflow_webhooks (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
            secret_ciphertext BYTEA NOT NULL, secret_nonce BYTEA NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (workflow_id)
        );
        CREATE INDEX IF NOT EXISTS workflow_webhooks_tenant_idx ON workflow_webhooks(tenant_id);
        """#).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS workflow_webhooks").run()
    }
}
