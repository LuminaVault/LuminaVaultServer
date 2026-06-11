@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-36 — proves the `memory_upsert` tool dispatch path actually
/// persists rows to the `memories` table during kb-compile. The stub
/// transport scripts two turns:
///
///   1. Assistant emits two `tool_calls` for `memory_upsert` with
///      distinct content payloads.
///   2. Tool results are appended; on the next chat call the assistant
///      emits a plain content message and the loop exits.
///
/// Asserts:
///   * Response `memoriesIngested == 2`.
///   * Two new rows landed under the caller's tenant in `memories`.
///   * `vault_files.processed_at` flipped on the seeded row.
@Suite(.serialized, .tags(.integration), .integrationDatabase)
struct MemoryCompileMemoryUpsertTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("kbm-\(suffix)@test.luminavault", "kbm-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: testPassword)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
    }

    private static func compileBody(_ request: KBCompileRequest) throws -> ByteBuffer {
        try ByteBuffer(data: JSONEncoder().encode(request))
    }

    private static func decodeCompileResponse(_ buffer: ByteBuffer) throws -> KBCompileResponse {
        try testJSONDecoder().decode(KBCompileResponse.self, from: Data(buffer: buffer))
    }

    private static func seedMarkdown(
        tenantID: UUID,
        relativePath: String,
        content: String,
        fluent: Fluent,
        rootPath: String
    ) async throws -> UUID {
        let raw = URL(fileURLWithPath: rootPath)
            .appendingPathComponent("tenants")
            .appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw")
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: raw.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(content.utf8)
        try data.write(to: raw, options: .atomic)
        let row = VaultFile(
            tenantID: tenantID,
            path: relativePath,
            contentType: "text/markdown",
            sizeBytes: Int64(data.count),
            sha256: String(repeating: "c", count: 64)
        )
        try await row.save(on: fluent.db())
        return try row.requireID()
    }

    @Test
    func `memory_upsert tool calls persist memories and roll up into response`() async throws {
        let stub = ScriptedChatTransport(turns: [
            Self.toolCallsTurn(calls: [
                ("call_1", "memory_upsert", #"{"content":"User prefers dark mode."}"#),
                ("call_2", "memory_upsert", #"{"content":"User journals every Sunday evening."}"#),
            ]),
            Self.contentTurn(text: "Stored 2 memories from this batch."),
        ])

        let app = try await buildApplication(
            reader: dbTestReader,
            kbCompileTransportOverride: stub
        )

        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let tenantID = auth.userId

            let rowID = try await withTestFluent(label: "lv.test.kb.memupsert.seed") { fluent -> UUID in
                try await Self.seedMarkdown(
                    tenantID: tenantID,
                    relativePath: "notes/preferences.md",
                    content: """
                    # Preferences

                    I prefer dark mode in every app I use.
                    I journal every Sunday evening before bed.
                    """,
                    fluent: fluent,
                    rootPath: "/tmp/luminavault-test"
                )
            }

            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [
                    .authorization: "Bearer \(auth.accessToken)",
                    .contentType: "application/json",
                ],
                body: Self.compileBody(KBCompileRequest())
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeCompileResponse(response.body)
                #expect(body.memoriesIngested == 2)
                #expect(body.durationMs ?? 0 > 0)
            }

            try await withTestFluent(label: "lv.test.kb.memupsert.assert") { fluent in
                let row = try await VaultFile.find(rowID, on: fluent.db())
                #expect(row?.processedAt != nil)

                let memoryRows = try await Memory.query(on: fluent.db())
                    .filter(\.$tenantID == tenantID)
                    .all()
                #expect(memoryRows.count == 2)
                let contents = Set(memoryRows.map(\.content))
                #expect(contents.contains("User prefers dark mode."))
                #expect(contents.contains("User journals every Sunday evening."))
            }
        }
    }

    // MARK: - Stub builders

    private static func toolCallsTurn(calls: [(id: String, name: String, args: String)]) -> String {
        let toolCallsJSON = calls.map { call in
            // The `arguments` field on the wire is a JSON-encoded STRING (not
            // a nested object), matching OpenAI's chat-completions spec.
            let escaped = call.args
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return """
            {
              "id": "\(call.id)",
              "type": "function",
              "function": {"name": "\(call.name)", "arguments": "\(escaped)"}
            }
            """
        }.joined(separator: ",")
        return """
        {
          "id": "stub-tool",
          "model": "stub-model",
          "choices": [{
            "message": {"role": "assistant", "content": null, "tool_calls": [\(toolCallsJSON)]},
            "finish_reason": "tool_calls"
          }]
        }
        """
    }

    private static func contentTurn(text: String) -> String {
        """
        {
          "id": "stub-final",
          "model": "stub-model",
          "choices": [{
            "message": {"role": "assistant", "content": "\(text)"},
            "finish_reason": "stop"
          }]
        }
        """
    }
}

// MARK: - Scripted transport

/// `HermesChatTransport` that returns canned response bodies in order, one
/// per `chatCompletions` call. Raises if the script is exhausted — that
/// would mean the agent loop ran more turns than the test scripted.
private actor ScriptedChatTransportInbox {
    private var turns: [String]
    init(turns: [String]) {
        self.turns = turns
    }

    func next() throws -> String {
        guard !turns.isEmpty else {
            throw ScriptedChatTransportError.exhausted
        }
        return turns.removeFirst()
    }
}

private enum ScriptedChatTransportError: Error {
    case exhausted
}

private struct ScriptedChatTransport: HermesChatTransport {
    let inbox: ScriptedChatTransportInbox

    init(turns: [String]) {
        inbox = ScriptedChatTransportInbox(turns: turns)
    }

    func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        let body = try await inbox.next()
        return Data(body.utf8)
    }
}
