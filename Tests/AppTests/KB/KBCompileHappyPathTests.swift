@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-36 happy-path coverage for `POST /v1/kb-compile`. Uses the
/// `kbCompileTransportOverride` hook on `buildApplication` to swap the
/// real Hermes chat transport for a deterministic stub that returns a
/// single assistant message with no tool calls — the loop exits after
/// one iteration with zero collected memories. That's enough to assert
/// the side effects the controller is responsible for:
///
///   * `vault_files.processed_at` is flipped on every row picked up.
///   * `OnboardingState.firstKBCompileCompleted` flips on the first
///     successful compile and is idempotent on the second call.
///   * Response carries `durationMs > 0`.
///
/// Coverage of memory upserts via the `memory_upsert` tool would need a
/// stub that emits tool-call JSON. Out of scope for the first pass.
@Suite(.serialized)
struct KBCompileHappyPathTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("kbh-\(suffix)@test.luminavault", "kbh-\(suffix)")
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

    private static func compileBody(_ request: KBCompileRequest) throws -> ByteBuffer {
        try ByteBuffer(data: JSONEncoder().encode(request))
    }

    private static func decodeCompileResponse(_ buffer: ByteBuffer) throws -> KBCompileResponse {
        try testJSONDecoder().decode(KBCompileResponse.self, from: Data(buffer: buffer))
    }

    /// Seeds one markdown file on disk + matching `vault_files` row with
    /// `processed_at` nil. Returns the row ID.
    private static func seedUnprocessedMarkdown(
        tenantID: UUID,
        relativePath: String,
        content: String,
        fluent: Fluent,
        rootPath: String,
    ) async throws -> UUID {
        let raw = URL(fileURLWithPath: rootPath)
            .appendingPathComponent("tenants")
            .appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw")
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: raw.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = Data(content.utf8)
        try data.write(to: raw, options: .atomic)

        let row = VaultFile(
            tenantID: tenantID,
            path: relativePath,
            contentType: "text/markdown",
            sizeBytes: Int64(data.count),
            sha256: String(repeating: "b", count: 64),
        )
        try await row.save(on: fluent.db())
        return try row.requireID()
    }

    @Test
    func `happy-path compile flips processedAt + onboarding flag, idempotent on second tap`() async throws {
        let app = try await buildApplication(
            reader: dbTestReader,
            kbCompileTransportOverride: StubHermesChatTransport(),
        )

        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let tenantID = auth.userId

            // Seed one markdown row + on-disk file.
            let rowID = try await withTestFluent(label: "lv.test.kb.happy.seed") { fluent -> UUID in
                try await Self.seedUnprocessedMarkdown(
                    tenantID: tenantID,
                    relativePath: "notes/hello.md",
                    content: "# Hello\n\nThis is a kb-compile test note.",
                    fluent: fluent,
                    rootPath: "/tmp/luminavault-test",
                )
            }

            // First compile — should pick up the row and flip processedAt.
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
                #expect(body.memoriesIngested == 0) // stub returned no tool calls
                #expect(body.durationMs ?? 0 > 0)
            }

            // Verify side effects.
            try await withTestFluent(label: "lv.test.kb.happy.assert") { fluent in
                let row = try await VaultFile.find(rowID, on: fluent.db())
                #expect(row?.processedAt != nil)

                let onboarding = try await OnboardingState
                    .query(on: fluent.db())
                    .filter(\.$tenantID == tenantID)
                    .first()
                #expect(onboarding?.firstKBCompileCompleted == true)
                #expect(onboarding?.firstKBCompileCompletedAt != nil)
            }

            // Second compile — nothing pending now, fast-path returns 0
            // without re-flipping or erroring.
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
                #expect(body.durationMs == 0)
            }
        }
    }
}

// MARK: - Stub transport

/// Returns a minimal `ChatResponseBody`-shaped JSON payload with a single
/// assistant message and no tool calls. The KB compile agent loop reads
/// `choices[0].message`, sees no `tool_calls`, and exits with the message
/// `content` as the summary.
private struct StubHermesChatTransport: HermesChatTransport {
    func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
        Data("""
        {
          "id": "test-1",
          "model": "test-model",
          "choices": [{
            "message": {"role": "assistant", "content": "Done — no memories worth storing in this stub."},
            "finish_reason": "stop"
          }]
        }
        """.utf8)
    }
}
