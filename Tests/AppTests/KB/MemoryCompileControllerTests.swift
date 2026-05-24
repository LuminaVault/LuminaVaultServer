@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-36 — HTTP-level coverage for `POST /v1/kb-compile`. The Hermes chat
/// transport is constructed by `buildApplication` and cannot be swapped
/// from a test, so these cases deliberately exercise only the paths that
/// short-circuit BEFORE the chat loop runs:
///
///   * Auth gate.
///   * Empty-pending fast-path (controller returns `memoriesIngested: 0`
///     without invoking the service).
///   * Tenant scoping of `vaultFileIds` filter (IDs that don't belong to
///     the caller are excluded by the Fluent query, so the controller
///     again sees an empty row set and returns 0).
///   * `OnboardingState.firstKBCompileCompleted` MUST remain `false` after
///     a no-op compile — the flag flip is gated on at least one row being
///     processed.
///
/// Full happy-path coverage (Hermes loop runs, memories upserted, flag
/// flips, achievement fires) needs a test-mode injection hook into
/// `MemoryCompileService`'s transport. Tracked separately.
@Suite(.serialized)
struct MemoryCompileControllerTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("kbc-\(suffix)@test.luminavault", "kbc-\(suffix)")
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

    private static func decodeCompileResponse(_ buffer: ByteBuffer) throws -> KBCompileResponse {
        try testJSONDecoder().decode(KBCompileResponse.self, from: Data(buffer: buffer))
    }

    /// Encodes a `KBCompileRequest` for the request body. Uses a vanilla
    /// `JSONEncoder` to mirror what the iOS client emits.
    private static func compileBody(_ request: KBCompileRequest) throws -> ByteBuffer {
        try ByteBuffer(data: JSONEncoder().encode(request))
    }

    // MARK: - Auth

    @Test
    func `unauthenticated kb-compile returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.compileBody(KBCompileRequest()),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - Empty-pending fast-path

    @Test
    func `compile with no pending vault files returns memoriesIngested 0`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [
                    .authorization: "Bearer \(auth.accessToken)",
                    .contentType: "application/json",
                ],
                body: Self.compileBody(KBCompileRequest()),
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeCompileResponse(response.body)
                #expect(body.memoriesIngested == 0)
                #expect(body.memoriesUpdated == 0)
                #expect(body.durationMs == 0)
                // HER-288 — empty-rows short-circuit still produces a fresh runId
                // that clients can use to correlate WS events.
                #expect(body.runId.uuidString.count == 36)
            }
        }
    }

    // MARK: - HER-288 — runId correlation

    @Test
    func `each compile response carries a unique runId`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            func compileRunId() async throws -> UUID {
                try await client.execute(
                    uri: "/v1/kb-compile",
                    method: .post,
                    headers: [
                        .authorization: "Bearer \(auth.accessToken)",
                        .contentType: "application/json",
                    ],
                    body: Self.compileBody(KBCompileRequest()),
                ) { response in
                    let body = try Self.decodeCompileResponse(response.body)
                    return body.runId
                }
            }

            let runIdA = try await compileRunId()
            let runIdB = try await compileRunId()
            #expect(runIdA != runIdB)
        }
    }

    @Test
    func `forceFullRecompile with no rows also returns 0`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [
                    .authorization: "Bearer \(auth.accessToken)",
                    .contentType: "application/json",
                ],
                body: Self.compileBody(KBCompileRequest(forceFullRecompile: true)),
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeCompileResponse(response.body)
                #expect(body.memoriesIngested == 0)
            }
        }
    }

    // MARK: - Tenant scoping

    @Test
    func `vaultFileIds from another tenant are filtered out`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            // Seed tenant A with one vault row, then attempt to compile it
            // from tenant B. The `filter(\.$tenantID == B.tenantID)` clause
            // in `resolveRows` must drop A's row → empty result → 200 + 0.
            let tenantA = try await Self.register(client: client)
            let tenantB = try await Self.register(client: client)

            let seededID = try await withTestFluent(label: "kbcompile.seed") { fluent -> UUID in
                let row = VaultFile(
                    tenantID: tenantA.userId,
                    path: "notes/leak.md",
                    contentType: "text/markdown",
                    sizeBytes: 12,
                    sha256: String(repeating: "a", count: 64),
                )
                try await row.save(on: fluent.db())
                return try row.requireID()
            }

            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [
                    .authorization: "Bearer \(tenantB.accessToken)",
                    .contentType: "application/json",
                ],
                body: Self.compileBody(KBCompileRequest(vaultFileIds: [seededID])),
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeCompileResponse(response.body)
                #expect(body.memoriesIngested == 0)
            }

            // Verify tenant A's row was NOT touched (`processed_at` stays nil).
            try await withTestFluent(label: "kbcompile.assert") { fluent in
                let row = try await VaultFile.find(seededID, on: fluent.db())
                #expect(row != nil)
                #expect(row?.processedAt == nil)
            }
        }
    }

    // MARK: - Onboarding flag is a one-way latch gated on successful compile

    @Test
    func `firstKBCompileCompleted stays false after a no-op compile`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [
                    .authorization: "Bearer \(auth.accessToken)",
                    .contentType: "application/json",
                ],
                body: Self.compileBody(KBCompileRequest()),
            ) { response in
                #expect(response.status == .ok)
            }

            try await client.execute(
                uri: "/v1/onboarding",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
                let state = try testJSONDecoder().decode(OnboardingStateDTO.self, from: Data(buffer: response.body))
                #expect(state.firstKBCompileCompleted == false)
                #expect(state.firstKBCompileCompletedAt == nil)
            }
        }
    }
}
