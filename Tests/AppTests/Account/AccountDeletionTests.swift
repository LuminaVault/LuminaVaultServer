@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import JWTKit
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// HER-92 end-to-end tests for `DELETE /v1/account`.
/// Run with `docker compose up -d postgres`.
///
/// Coverage:
///   * password gate (correct / incorrect / missing)
///   * fresh-JWT gate
///   * cascade verification across every FK-owned child table
///   * tenant isolation (token for user A cannot wipe user B)
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AccountDeletionTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("acct-\(suffix)@test.luminavault", "acct-\(suffix)")
    }

    /// Registers a user, returns the response (includes userId + accessToken).
    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: testPassword)
        ) { try decodeAuthResponse($0.body) }
    }

    @Test
    func `delete with correct password returns 204`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test
    func `delete with wrong password returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"password":"definitely-wrong"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `delete with fresh JWT and no password succeeds`() async throws {
        // The JWT minted by /register has `iat ≈ now`, well inside the 5-minute
        // fresh-auth window — so omitting `password` is acceptable.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test
    func `delete with stale JWT and no password returns 401`() async throws {
        // Mint a token that's structurally valid but whose `iat` is 10 minutes
        // old — outside the 5-min fresh-auth window. Password is omitted, so
        // the only re-auth path is fresh-JWT, which fails.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            let keys = JWTKeyCollection()
            let kid = JWKIdentifier(string: "test-kid")
            await keys.add(
                hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"),
                digestAlgorithm: .sha256, kid: kid
            )
            let now = Date()
            let stale = SessionToken(
                userID: auth.userId,
                expiration: now.addingTimeInterval(3600),
                issuedAt: now.addingTimeInterval(-600)
            )
            let signed = try await keys.sign(stale, kid: kid)

            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(signed)", .contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `unauthenticated returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/account", method: .delete) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `delete cascades across all child tables`() async throws {
        // Drives a single user through the full life cycle: register, push
        // device token, upsert a memory, set onboarding flags, delete.
        // Verifies the `users` row AND every FK-owned table is empty for
        // the deleted tenant.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let token = auth.accessToken
            let tenantID = auth.userId

            // 1) Device token row
            let deviceBody = ByteBuffer(string: #"{"token":"apns-\#(UUID().uuidString)","platform":"ios"}"#)
            try await client.execute(
                uri: "/v1/devices",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: deviceBody
            ) { #expect($0.status == .ok || $0.status == .created) }

            // 2) Memory row
            let memBody = ByteBuffer(string: #"{"content":"will be wiped"}"#)
            try await client.execute(
                uri: "/v1/memory/upsert",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: memBody
            ) { #expect($0.status == .ok || $0.status == .created) }

            // 3) Onboarding row (lazy-created on first GET)
            try await client.execute(
                uri: "/v1/onboarding",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { #expect($0.status == .ok) }

            // 4) Delete
            let delBody = ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: delBody
            ) { #expect($0.status == .noContent) }

            // 5) Verify cascade in DB directly. We can't reach the app's Fluent
            // handle from the test, so spin up an ephemeral one against the
            // same test database. HER-310 — `withTestFluent` guarantees
            // shutdown completes before returning (avoids AsyncKit pool
            // assertion at process exit).
            try await withTestFluent(label: "test.account.delete") { fluent in
                try await Self.expectEmpty(table: "users", tenantColumn: "id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "refresh_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "password_reset_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "mfa_challenges", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "oauth_identities", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "memories", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "hermes_profiles", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "device_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "webauthn_credentials", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "spaces", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "vault_files", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "health_events", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "email_verification_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
                try await Self.expectEmpty(table: "onboarding_state", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            }
        }
    }

    @Test
    func `tenant isolation cannot delete another user`() async throws {
        // Mallory's token must not authorize wiping Alice. The DELETE acts
        // on the authenticated identity, not a path parameter, so an attacker
        // can't even target Alice's userID — but verify Alice survives anyway.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.register(client: client)
            let mallory = try await Self.register(client: client)

            let body = ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(mallory.accessToken)", .contentType: "application/json"],
                body: body
            ) { #expect($0.status == .noContent) }

            try await withTestFluent(label: "test.account.delete") { fluent in
                let aliceRow = try await User.find(alice.userId, on: fluent.db())
                #expect(aliceRow != nil, "Alice's row must survive Mallory's account deletion")
            }
        }
    }

    // MARK: - Rows no cascade reaches (TenantDataEraser)

    @Test
    func `delete erases tenant rows that have no cascade and spares other tenants`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.register(client: client)
            let bob = try await Self.register(client: client)

            try await withTestFluent(label: "test.account.erase.seed") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                for tenant in [alice.userId, bob.userId] {
                    try await Self.seedUnkeyedRows(tenantID: tenant, sql: sql)
                }
                // Alice acted in Bob's vault: the row is Bob's and must stay,
                // but it carried Alice's name.
                try await sql.raw("""
                INSERT INTO vault_activity_events (id, vault_id, actor_user_id, actor_name, action, target_type, created_at)
                VALUES (gen_random_uuid(), \(bind: bob.userId), \(bind: alice.userId), 'alice-display-name', 'note.created', 'note', NOW())
                """).run()
            }

            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(alice.accessToken)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            ) { #expect($0.status == .noContent) }

            try await withTestFluent(label: "test.account.erase.verify") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                for table in TenantDataEraser.erasedTables {
                    #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM \(table) WHERE tenant_id = $1", alice.userId) == 0, "\(table) kept the deleted tenant's rows")
                    #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM \(table) WHERE tenant_id = $1", bob.userId) >= 1, "\(table) lost another tenant's rows")
                }
                // Messages hang off the room by cascade; seeded one per room.
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM agent_room_messages m JOIN agent_rooms r ON r.id = m.room_id WHERE r.tenant_id = $1", bob.userId) == 1)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM agent_room_messages m WHERE NOT EXISTS (SELECT 1 FROM agent_rooms r WHERE r.id = m.room_id)", nil) == 0)

                for tenant in [alice.userId, bob.userId] {
                    let expected = tenant == alice.userId ? 0 : 2
                    #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM workflow_spend_buckets WHERE lower(scope_key) LIKE '%' || lower($1::text)", tenant) == expected)
                }

                // Billing: retained, de-identified.
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM billing_event_logs WHERE user_id = $1", alice.userId) == 0)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM billing_event_logs WHERE event_id = 'evt-' || $1::text AND user_id IS NULL", alice.userId) == 1)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM billing_event_logs WHERE user_id = $1", bob.userId) == 1)

                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM vault_activity_events WHERE actor_name = 'alice-display-name'", nil) == 0)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM vault_activity_events WHERE vault_id = $1 AND actor_user_id IS NULL AND actor_name = 'Deleted user'", bob.userId) == 1)
            }
        }
    }

    /// Fails when a migration adds a table with a `tenant_id` / `user_id`
    /// column that neither cascades from `users` nor appears in
    /// `TenantDataEraser`. That is how the original gap opened: each table
    /// was added without a cascade and nothing noticed.
    @Test
    func `every tenant table is erased or cascades`() async throws {
        try await withTestFluent(label: "test.account.erase.schema") { fluent in
            let sql = try #require(fluent.db() as? any SQLDatabase)
            struct Row: Decodable { let table_name: String }
            let rows = try await sql.raw("""
            WITH RECURSIVE fk AS (
                SELECT c.conrelid::regclass::text AS child, c.confrelid::regclass::text AS parent, c.confdeltype::text AS del
                FROM pg_constraint c WHERE c.contype = 'f'
            ),
            reach(tbl) AS (
                SELECT 'users'::text
                UNION
                SELECT fk.child FROM fk JOIN reach r ON fk.parent = r.tbl WHERE fk.del = 'c'
            )
            SELECT DISTINCT c.table_name::text AS table_name
            FROM information_schema.columns c
            WHERE c.table_schema = 'public'
              AND c.column_name IN ('tenant_id', 'user_id')
              AND c.table_name::text NOT IN (SELECT tbl FROM reach)
            ORDER BY 1
            """).all(decoding: Row.self)
            let covered = Set(TenantDataEraser.erasedTables + TenantDataEraser.anonymizedTables + TenantDataEraser.handledElsewhere)
            let uncovered = rows.map(\.table_name).filter { !covered.contains($0) }
            #expect(uncovered.isEmpty, "tenant tables with no cascade from users and no entry in TenantDataEraser: \(uncovered)")
        }
    }

    @Test
    func `delete soft-renames the Hermes profile directory under profiles`() async throws {
        let hermesRoot = "/tmp/luminavault-test-hermes"
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let profileID = try await withTestFluent(label: "test.account.hermes") { fluent in
                try await HermesProfile.query(on: fluent.db(), tenantID: auth.userId).first()?.hermesProfileID
            }
            let hpid = try #require(profileID)
            let profiles = HermesDataPathService(hermesDataRoot: hermesRoot).profilesRoot()
            let live = profiles.appendingPathComponent(hpid)
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            try Data("soul".utf8).write(to: live.appendingPathComponent("SOUL.md"))
            defer {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []
                    where name == hpid || name.hasSuffix(auth.userId.uuidString)
                {
                    try? FileManager.default.removeItem(at: profiles.appendingPathComponent(name))
                }
            }

            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            ) { #expect($0.status == .noContent) }

            #expect(!FileManager.default.fileExists(atPath: live.path), "live Hermes profile dir survived deletion")
            let renamed = try FileManager.default.contentsOfDirectory(atPath: profiles.path)
                .filter { DeletedDataPurgeJob.parse($0, identity: .profileName)?.id == auth.userId.uuidString }
            #expect(renamed.count == 1)
        }
    }

    @Test
    func `M150 removes rows orphaned by earlier deletions and keeps live ones`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let live = try await Self.register(client: client)
            let orphan = UUID()
            try await withTestFluent(label: "test.account.m150") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                try await Self.seedUnkeyedRows(tenantID: live.userId, sql: sql)
                try await Self.seedUnkeyedRows(tenantID: orphan, sql: sql)
                try await sql.raw("""
                INSERT INTO vault_activity_events (id, vault_id, actor_user_id, actor_name, action, target_type, created_at)
                VALUES (gen_random_uuid(), \(bind: live.userId), NULL, 'gone-person', 'note.created', 'note', NOW())
                """).run()

                try await M150_PurgeOrphanedTenantRows().prepare(on: fluent.db())

                for table in TenantDataEraser.erasedTables {
                    #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM \(table) WHERE tenant_id = $1", orphan) == 0, "\(table) kept orphan rows")
                    #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM \(table) WHERE tenant_id = $1", live.userId) >= 1, "\(table) lost a live tenant's rows")
                }
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM workflow_spend_buckets WHERE lower(scope_key) LIKE '%' || lower($1::text)", orphan) == 0)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM workflow_spend_buckets WHERE lower(scope_key) LIKE '%' || lower($1::text)", live.userId) == 2)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM billing_event_logs WHERE event_id = 'evt-' || $1::text AND user_id IS NULL", orphan) == 1)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM billing_event_logs WHERE user_id = $1", live.userId) == 1)
                #expect(try await Self.count(sql, "SELECT COUNT(*)::int AS n FROM vault_activity_events WHERE actor_name = 'gone-person'", nil) == 0)
            }
        }
    }

    // MARK: - Helpers

    /// One row per `TenantDataEraser.erasedTables` entry (plus a room message,
    /// both spend-bucket spellings and a billing event) for `tenantID`.
    private static func seedUnkeyedRows(tenantID: UUID, sql: any SQLDatabase) async throws {
        let roomID = UUID()
        try await sql.raw("""
        INSERT INTO agent_rooms (id, tenant_id, title, created_at, updated_at)
        VALUES (\(bind: roomID), \(bind: tenantID), 'room', NOW(), NOW())
        """).run()
        try await sql.raw("""
        INSERT INTO agent_room_messages (id, room_id, author_kind, body, created_at)
        VALUES (gen_random_uuid(), \(bind: roomID), 'user', 'private words', NOW())
        """).run()
        try await sql.raw("""
        INSERT INTO device_command_queue (id, tenant_id, kind, payload, created_at, expires_at)
        VALUES (gen_random_uuid(), \(bind: tenantID), 'reminder_create', '{"title":"x"}', NOW(), NOW() + interval '1 day')
        """).run()
        try await sql.raw("""
        INSERT INTO idempotency_keys (id, tenant_id, key, request_hash, response_status, response_body, created_at, expires_at)
        VALUES (gen_random_uuid(), \(bind: tenantID), gen_random_uuid(), 'h', 200, '\\x7b7d'::bytea, NOW(), NOW() + interval '1 day')
        """).run()
        try await sql.raw("""
        INSERT INTO embedding_usage (id, tenant_id, year_month, tokens_used, created_at, updated_at)
        VALUES (gen_random_uuid(), \(bind: tenantID), '1999-01', 10, NOW(), NOW())
        """).run()
        try await sql.raw("""
        INSERT INTO retrieval_telemetry_events (id, tenant_id, source_path, hit_count, zero_hit, limit_requested, created_at)
        VALUES (gen_random_uuid(), \(bind: tenantID), 'chat', 1, false, 5, NOW())
        """).run()
        try await sql.raw("""
        INSERT INTO retrieval_leak_reports (id, tenant_id, period_start, period_end, total_retrievals, zero_hit_count, zero_hit_rate, created_at)
        VALUES (gen_random_uuid(), \(bind: tenantID), NOW() - interval '7 days', NOW(), 10, 1, 0.1, NOW())
        """).run()
        for key in ["tenant:\(tenantID.uuidString)", "freelane:tenant:\(tenantID.uuidString)"] {
            try await sql.raw("""
            INSERT INTO workflow_spend_buckets (scope_key, period_kind, period_start)
            VALUES (\(bind: key), 'day', CURRENT_DATE)
            """).run()
        }
        try await sql.raw("""
        INSERT INTO billing_event_logs (id, event_id, event_type, user_id, processed_at)
        VALUES (gen_random_uuid(), \(bind: "evt-\(tenantID.uuidString.lowercased())"), 'INITIAL_PURCHASE', \(bind: tenantID), NOW())
        """).run()
    }

    private static func count(_ sql: any SQLDatabase, _ query: String, _ id: UUID?) async throws -> Int {
        struct CountRow: Decodable { let n: Int }
        // Test-only SQL with a single optional `$1` bind.
        let rows: [CountRow] = if let id {
            try await sql.raw("\(unsafeRaw: query.replacingOccurrences(of: "$1", with: "'\(id.uuidString.lowercased())'::uuid"))")
                .all(decoding: CountRow.self)
        } else {
            try await sql.raw("\(unsafeRaw: query)").all(decoding: CountRow.self)
        }
        return rows.first?.n ?? -1
    }

    private static func expectEmpty(
        table: String,
        tenantColumn: String,
        tenantID: UUID,
        fluent: Fluent
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            Issue.record("SQL driver unavailable")
            return
        }
        struct CountRow: Decodable { let n: Int }
        // Whitelisted identifiers (test code, no external input) so we can
        // splice them into the SQL string without parameterisation.
        let rows = try await sql.raw("""
        SELECT COUNT(*)::int AS n FROM \(unsafeRaw: table) WHERE \(unsafeRaw: tenantColumn) = \(bind: tenantID)
        """).all(decoding: CountRow.self)
        #expect(rows.first?.n == 0, "expected \(table) to be empty after cascade, got \(rows.first?.n ?? -1)")
    }
}
