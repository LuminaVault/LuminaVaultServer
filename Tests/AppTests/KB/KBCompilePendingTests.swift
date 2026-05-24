@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-293 — HTTP coverage for `GET /v1/kb-compile/pending`. The endpoint
/// powers the iOS "Sync & Learn" disabled-state UX (HER-108) and must:
///
///   * Require auth (401 without a Bearer token).
///   * Return `pendingFiles: 0` for a fresh tenant with no vault rows.
///   * Return the live count of rows where `processed_at IS NULL`.
///   * Stay strictly tenant-scoped — another tenant's pending rows are
///     invisible.
///   * Exclude rows that already have a non-nil `processed_at`.
@Suite(.serialized)
struct KBCompilePendingTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("kbp-\(suffix)@test.luminavault", "kbp-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: testPassword),
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
    }

    private static func decodePending(_ buffer: ByteBuffer) throws -> KBCompilePendingResponse {
        try testJSONDecoder().decode(KBCompilePendingResponse.self, from: Data(buffer: buffer))
    }

    private static func seedVaultFile(
        tenantID: UUID,
        path: String,
        processedAt: Date? = nil,
    ) async throws -> UUID {
        try await withTestFluent(label: "kbcompile.pending.seed") { fluent -> UUID in
            let row = VaultFile(
                tenantID: tenantID,
                path: path,
                contentType: "text/markdown",
                sizeBytes: 12,
                sha256: String(repeating: "a", count: 64),
                processedAt: processedAt,
            )
            try await row.save(on: fluent.db())
            return try row.requireID()
        }
    }

    // MARK: - Auth

    @Test
    func `unauthenticated pending returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/kb-compile/pending",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - Empty tenant

    @Test
    func `fresh tenant with no vault rows returns 0`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/kb-compile/pending",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodePending(response.body)
                #expect(body.pendingFiles == 0)
            }
        }
    }

    // MARK: - Counting

    @Test
    func `counts only rows with processedAt nil`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            // Two unprocessed + one already processed → expect 2.
            _ = try await Self.seedVaultFile(tenantID: auth.userId, path: "notes/a.md")
            _ = try await Self.seedVaultFile(tenantID: auth.userId, path: "notes/b.md")
            _ = try await Self.seedVaultFile(
                tenantID: auth.userId,
                path: "notes/c.md",
                processedAt: Date(),
            )

            try await client.execute(
                uri: "/v1/kb-compile/pending",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodePending(response.body)
                #expect(body.pendingFiles == 2)
            }
        }
    }

    // MARK: - Tenant scoping

    @Test
    func `another tenants pending rows are invisible`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantA = try await Self.register(client: client)
            let tenantB = try await Self.register(client: client)

            // Seed two unprocessed rows for A. B must see 0.
            _ = try await Self.seedVaultFile(tenantID: tenantA.userId, path: "a/one.md")
            _ = try await Self.seedVaultFile(tenantID: tenantA.userId, path: "a/two.md")

            try await client.execute(
                uri: "/v1/kb-compile/pending",
                method: .get,
                headers: [.authorization: "Bearer \(tenantB.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodePending(response.body)
                #expect(body.pendingFiles == 0)
            }

            // Sanity: A still sees its own 2.
            try await client.execute(
                uri: "/v1/kb-compile/pending",
                method: .get,
                headers: [.authorization: "Bearer \(tenantA.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodePending(response.body)
                #expect(body.pendingFiles == 2)
            }
        }
    }
}
