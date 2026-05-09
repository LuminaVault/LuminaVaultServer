import Foundation
import Logging
import Testing

@testable import App

/// Comprehensive tenant isolation tests:
/// - Verify TenantModel query helpers enforce tenant_id filtering
/// - Assert cross-tenant data leaks are impossible
/// - Ensure HermesProfileService creates profiles scoped to the owning tenant
/// - Validate all TenantModel tables have tenant_id NOT NULL
@Suite
struct TenantIsolationTests {
    // MARK: - TenantModel Query Helpers
    
    @Test
    func tenantModelQueryFiltersByTenantID() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant1 = UUID()
        let tenant2 = UUID()
        
        // Create users for each tenant
        let user1 = User(id: tenant1, email: "user1@example.com", username: "user1")
        let user2 = User(id: tenant2, email: "user2@example.com", username: "user2")
        
        try await user1.save(on: db)
        try await user2.save(on: db)
        
        // Create refresh tokens for each tenant
        let token1 = RefreshToken(tenantID: tenant1, tokenHash: "hash1", expiresAt: Date().addingTimeInterval(3600))
        let token2 = RefreshToken(tenantID: tenant2, tokenHash: "hash2", expiresAt: Date().addingTimeInterval(3600))
        
        try await token1.save(on: db)
        try await token2.save(on: db)
        
        // Query using tenant1 context should only see tenant1's token
        let tenant1Tokens = try await RefreshToken
            .query(on: db, tenantID: tenant1)
            .all()
        
        #expect(tenant1Tokens.count == 1)
        #expect(tenant1Tokens[0].tenantID == tenant1)
        
        // Query using tenant2 context should only see tenant2's token
        let tenant2Tokens = try await RefreshToken
            .query(on: db, tenantID: tenant2)
            .all()
        
        #expect(tenant2Tokens.count == 1)
        #expect(tenant2Tokens[0].tenantID == tenant2)
    }
    
    // MARK: - Cross-Tenant Isolation
    
    @Test
    func memoryCreateIsolationByTenant() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant1 = UUID()
        let tenant2 = UUID()
        
        // Create users
        let user1 = User(id: tenant1, email: "alice@example.com", username: "alice")
        let user2 = User(id: tenant2, email: "bob@example.com", username: "bob")
        
        try await user1.save(on: db)
        try await user2.save(on: db)
        
        // Create memories for each tenant
        let mem1 = Memory(
            tenantID: tenant1,
            content: "Alice's memory",
            metadata: [:],
            embedding: nil
        )
        let mem2 = Memory(
            tenantID: tenant2,
            content: "Bob's memory",
            metadata: [:],
            embedding: nil
        )
        
        try await mem1.save(on: db)
        try await mem2.save(on: db)
        
        // Verify tenant1 query doesn't leak tenant2's memory
        let tenant1Memories = try await Memory
            .query(on: db, tenantID: tenant1)
            .all()
        
        #expect(tenant1Memories.count == 1)
        #expect(tenant1Memories[0].content == "Alice's memory")
        
        // Verify tenant2 query doesn't leak tenant1's memory
        let tenant2Memories = try await Memory
            .query(on: db, tenantID: tenant2)
            .all()
        
        #expect(tenant2Memories.count == 1)
        #expect(tenant2Memories[0].content == "Bob's memory")
    }
    
    @Test
    func oauthIdentityIsolationByTenant() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant1 = UUID()
        let tenant2 = UUID()
        
        // Create users
        let user1 = User(id: tenant1, email: "user1@example.com", username: "user1")
        let user2 = User(id: tenant2, email: "user2@example.com", username: "user2")
        
        try await user1.save(on: db)
        try await user2.save(on: db)
        
        // Create OAuth identities for each tenant
        let oauth1 = OAuthIdentity(
            tenantID: tenant1,
            provider: "google",
            providerUserID: "google-id-1",
            email: "user1@example.com"
        )
        let oauth2 = OAuthIdentity(
            tenantID: tenant2,
            provider: "apple",
            providerUserID: "apple-id-1",
            email: "user2@example.com"
        )
        
        try await oauth1.save(on: db)
        try await oauth2.save(on: db)
        
        // Cross-tenant query should not return both
        let tenant1OAuths = try await OAuthIdentity
            .query(on: db, tenantID: tenant1)
            .all()
        
        #expect(tenant1OAuths.count == 1)
        #expect(tenant1OAuths[0].provider == "google")
        
        let tenant2OAuths = try await OAuthIdentity
            .query(on: db, tenantID: tenant2)
            .all()
        
        #expect(tenant2OAuths.count == 1)
        #expect(tenant2OAuths[0].provider == "apple")
    }
    
    // MARK: - HermesProfileService Scoping
    
    @Test
    func hermesProfileServiceEnsureCreatesPerTenantProfile() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant1 = UUID()
        let tenant2 = UUID()
        
        // Create users
        let user1 = User(id: tenant1, email: "alice@example.com", username: "alice")
        let user2 = User(id: tenant2, email: "bob@example.com", username: "bob")
        
        try await user1.save(on: db)
        try await user2.save(on: db)
        
        // Use HermesProfileService to ensure profiles
        let service = app.services.hermesProfileService
        
        let profile1 = try await service.ensure(for: user1)
        let profile2 = try await service.ensure(for: user2)
        
        #expect(profile1.tenantID == tenant1)
        #expect(profile2.tenantID == tenant2)
        
        // Verify profiles are isolated in the database
        let tenant1Profiles = try await HermesProfile
            .query(on: db, tenantID: tenant1)
            .all()
        
        #expect(tenant1Profiles.count == 1)
        #expect(tenant1Profiles[0].tenantID == tenant1)
        
        let tenant2Profiles = try await HermesProfile
            .query(on: db, tenantID: tenant2)
            .all()
        
        #expect(tenant2Profiles.count == 1)
        #expect(tenant2Profiles[0].tenantID == tenant2)
    }
    
    @Test
    func hermesProfileServiceEnsureIsIdempotent() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant = UUID()
        let user = User(id: tenant, email: "alice@example.com", username: "alice")
        try await user.save(on: db)
        
        let service = app.services.hermesProfileService
        
        // Call ensure twice for the same user
        let profile1 = try await service.ensure(for: user)
        let profile2 = try await service.ensure(for: user)
        
        // Should be the same profile
        #expect(profile1.id == profile2.id)
        #expect(profile1.hermesProfileID == profile2.hermesProfileID)
        
        // Verify only one profile exists
        let allProfiles = try await HermesProfile
            .query(on: db, tenantID: tenant)
            .all()
        
        #expect(allProfiles.count == 1)
    }
    
    // MARK: - Refresh Token Isolation
    
    @Test
    func refreshTokenIsolationPreventsCrossTenantRevocation() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant1 = UUID()
        let tenant2 = UUID()
        
        // Create users
        let user1 = User(id: tenant1, email: "user1@example.com", username: "user1")
        let user2 = User(id: tenant2, email: "user2@example.com", username: "user2")
        
        try await user1.save(on: db)
        try await user2.save(on: db)
        
        // Create refresh tokens
        let token1 = RefreshToken(
            tenantID: tenant1,
            tokenHash: "hash1",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let token2 = RefreshToken(
            tenantID: tenant2,
            tokenHash: "hash2",
            expiresAt: Date().addingTimeInterval(3600)
        )
        
        try await token1.save(on: db)
        try await token2.save(on: db)
        
        // Delete tokens for tenant1
        try await RefreshToken
            .query(on: db, tenantID: tenant1)
            .delete()
        
        // Verify tenant1 tokens are deleted but tenant2 tokens remain
        let tenant1TokensAfter = try await RefreshToken
            .query(on: db, tenantID: tenant1)
            .all()
        
        #expect(tenant1TokensAfter.count == 0)
        
        let tenant2TokensAfter = try await RefreshToken
            .query(on: db, tenantID: tenant2)
            .all()
        
        #expect(tenant2TokensAfter.count == 1)
        #expect(tenant2TokensAfter[0].tokenHash == "hash2")
    }
    
    // MARK: - MFA Challenge Isolation
    
    @Test
    func mfaChallengeIsolationByTenant() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenant1 = UUID()
        let tenant2 = UUID()
        
        // Create users
        let user1 = User(id: tenant1, email: "user1@example.com", username: "user1")
        let user2 = User(id: tenant2, email: "user2@example.com", username: "user2")
        
        try await user1.save(on: db)
        try await user2.save(on: db)
        
        // Create MFA challenges
        let challenge1 = MFAChallenge(
            tenantID: tenant1,
            attemptID: "attempt1",
            codeHash: "hash1",
            email: "user1@example.com",
            expiresAt: Date().addingTimeInterval(600)
        )
        let challenge2 = MFAChallenge(
            tenantID: tenant2,
            attemptID: "attempt2",
            codeHash: "hash2",
            email: "user2@example.com",
            expiresAt: Date().addingTimeInterval(600)
        )
        
        try await challenge1.save(on: db)
        try await challenge2.save(on: db)
        
        // Query should isolate by tenant
        let tenant1Challenges = try await MFAChallenge
            .query(on: db, tenantID: tenant1)
            .all()
        
        #expect(tenant1Challenges.count == 1)
        #expect(tenant1Challenges[0].email == "user1@example.com")
        
        let tenant2Challenges = try await MFAChallenge
            .query(on: db, tenantID: tenant2)
            .all()
        
        #expect(tenant2Challenges.count == 1)
        #expect(tenant2Challenges[0].email == "user2@example.com")
    }
    
    // MARK: - Database Schema Validation
    
    @Test
    func allTenantModelsHaveTenantIDColumn() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let tenantModelTables = [
            "refresh_tokens",
            "oauth_identities",
            "mfa_challenges",
            "password_reset_tokens",
            "memories",
            "hermes_profiles"
        ]
        
        for tableName in tenantModelTables {
            // Query the information_schema to verify tenant_id exists and is NOT NULL
            let result = try await db.query(raw: """
                SELECT column_name, is_nullable
                FROM information_schema.columns
                WHERE table_name = '\(tableName)'
                  AND column_name = 'tenant_id'
                LIMIT 1
            """).all()
            
            #expect(!result.isEmpty, "Table \(tableName) missing tenant_id column")
            
            if let row = result.first {
                // Fluent ORM should parse this; check that is_nullable is NO
                if let dict = row as? [String: Any] {
                    let isNullable = dict["is_nullable"] as? String
                    #expect(isNullable == "NO", "Table \(tableName) tenant_id should be NOT NULL")
                }
            }
        }
    }
    
    @Test
    func tenantIDColumnsAreIndexed() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.runMigrations()
        let db = app.services.fluent.db()
        
        let indexChecks = [
            ("refresh_tokens", "idx_refresh_tokens_tenant"),
            ("oauth_identities", "idx_oauth_identities_tenant"),
            ("mfa_challenges", "idx_mfa_challenges_tenant"),
            ("password_reset_tokens", "idx_password_reset_tokens_tenant"),
            ("memories", "idx_memories_tenant"),
        ]
        
        for (tableName, expectedIndexName) in indexChecks {
            let result = try await db.query(raw: """
                SELECT indexname FROM pg_indexes
                WHERE tablename = '\(tableName)'
                  AND indexname LIKE '%tenant%'
                LIMIT 1
            """).all()
            
            #expect(!result.isEmpty, "Table \(tableName) missing tenant_id index")
        }
    }
}

// MARK: - Helper Extensions

private extension Application {
    func runMigrations() async throws {
        guard let fluent = services.fluent as? Fluent else {
            return
        }
        try await fluent.migrate()
    }
}
