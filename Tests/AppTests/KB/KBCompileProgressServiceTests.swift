@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// HER-288 Task 6 — drives `MemoryCompileService.compileExistingVaultFiles`
/// against a scripted `HermesChatTransport` and asserts the *service-level*
/// progress events fire in the right order:
///
///   * Happy path: `.preparing` lands first, at least one `.thinking`
///     event, at least one `.memorySaved` event. `.started` and `.completed`
///     are emitted by the controller (Task 7/9) — not asserted here.
///   * Error path: when the transport raises, the service rethrows and the
///     recorder must NOT contain `.completed` or `.error` (controller's job).
///
/// Pattern mirrors `KBCompileSpaceCountersTests` — go around `buildApplication`
/// and call the service directly so the suite stays focused on the service
/// contract.
@Suite("MemoryCompileService progress ordering")
struct KBCompileProgressServiceTests {
    @Test func `happy path emits preparing then thinking then memory saved`() async throws {
        try await withTestFluent(label: "lv.test.kbcompile.progress.happy") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let db = fluent.db()

            let tenantID = try await Self.seedUser(on: fluent)

            // Set up a temp vault root with one markdown file on disk and a
            // matching `vault_files` row so `compileExistingVaultFiles` has a
            // real payload to read + a real row id to flip.
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-kbprog-\(UUID().uuidString)", isDirectory: true)
            let vaultPaths = VaultPathService(rootPath: rootURL.path)
            let relativePath = "notes/progress.md"
            try Self.writeFile(
                tenantID: tenantID,
                rootPath: rootURL.path,
                relativePath: relativePath,
                content: "# Progress\n\nUser prefers chunky markdown sections.",
            )
            let row = VaultFile(
                tenantID: tenantID,
                path: relativePath,
                contentType: "text/markdown",
                sizeBytes: 64,
                sha256: String(repeating: "d", count: 64),
            )
            try await row.save(on: db)

            let recorder = RecordingProgressPublisher()
            let transport = ScriptedChatTransport(turns: [
                // Turn 1: emit one `memory_upsert` tool call.
                Self.toolCallTurn(
                    id: "call_1",
                    name: "memory_upsert",
                    argsJSON: #"{"content":"User prefers chunky markdown sections."}"#,
                ),
                // Turn 2: plain assistant content → loop exits.
                Self.contentTurn(text: "Stored 1 memory from this batch."),
            ])

            let service = MemoryCompileService(
                vaultPaths: vaultPaths,
                transport: transport,
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test-model",
                logger: Logger(label: "lv.test.kbcompile.progress.happy"),
                progress: recorder,
            )

            let runId = UUID()
            _ = try await service.compileExistingVaultFiles(
                tenantID: tenantID,
                sessionKey: "test-user",
                rows: [row],
                hint: nil,
                runId: runId,
            )

            let observed = await recorder.snapshot()
            let types: [String] = observed.map(Self.label(of:))

            // Service emits `.preparing` first, before the agent loop kicks
            // in. Controller-level `.started` is NOT expected here.
            #expect(types.first == "preparing")
            #expect(types.contains("thinking"))
            #expect(types.contains("memorySaved"))
            #expect(!types.contains("started"))
            #expect(!types.contains("completed"))
            #expect(!types.contains("error"))

            // Ordering: every `.memorySaved` arrives AFTER a `.thinking` in
            // the same iteration, and after the initial `.preparing`.
            let preparingIdx = try #require(types.firstIndex(of: "preparing"))
            let thinkingIdx = try #require(types.firstIndex(of: "thinking"))
            let memorySavedIdx = try #require(types.firstIndex(of: "memorySaved"))
            #expect(preparingIdx < thinkingIdx)
            #expect(thinkingIdx < memorySavedIdx)

            // Every event carries our runId.
            for event in observed {
                #expect(Self.runId(of: event) == runId)
            }
        }
    }

    @Test func `error path bubbles up and service emits no completion`() async throws {
        try await withTestFluent(label: "lv.test.kbcompile.progress.error") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let db = fluent.db()

            let tenantID = try await Self.seedUser(on: fluent)

            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-kbprog-\(UUID().uuidString)", isDirectory: true)
            let vaultPaths = VaultPathService(rootPath: rootURL.path)
            let relativePath = "notes/will-fail.md"
            try Self.writeFile(
                tenantID: tenantID,
                rootPath: rootURL.path,
                relativePath: relativePath,
                content: "# Will fail\n\nTransport will throw on the first turn.",
            )
            let row = VaultFile(
                tenantID: tenantID,
                path: relativePath,
                contentType: "text/markdown",
                sizeBytes: 64,
                sha256: String(repeating: "e", count: 64),
            )
            try await row.save(on: db)

            let recorder = RecordingProgressPublisher()
            let transport = ThrowingChatTransport()

            let service = MemoryCompileService(
                vaultPaths: vaultPaths,
                transport: transport,
                memories: MemoryRepository(fluent: fluent),
                embeddings: DeterministicEmbeddingService(),
                defaultModel: "test-model",
                logger: Logger(label: "lv.test.kbcompile.progress.error"),
                progress: recorder,
            )

            let runId = UUID()
            await #expect(throws: (any Error).self) {
                _ = try await service.compileExistingVaultFiles(
                    tenantID: tenantID,
                    sessionKey: "test-user",
                    rows: [row],
                    hint: nil,
                    runId: runId,
                )
            }

            let observed = await recorder.snapshot()
            let types = observed.map(Self.label(of:))

            // Service must NEVER emit terminal envelopes — those belong to
            // the controller (Task 7).
            #expect(!types.contains("completed"))
            #expect(!types.contains("error"))
            #expect(!types.contains("started"))

            // Sanity: we did get at least `.preparing` before the throw.
            #expect(types.contains("preparing"))
        }
    }

    // MARK: - Helpers

    private static func seedUser(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let slug = "kbp\(UUID().uuidString.prefix(6).lowercased())"
        let user = User(
            id: id,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-\(slug)",
        )
        try await user.save(on: fluent.db())
        return id
    }

    private static func writeFile(
        tenantID: UUID,
        rootPath: String,
        relativePath: String,
        content: String,
    ) throws {
        let target = URL(fileURLWithPath: rootPath)
            .appendingPathComponent("tenants")
            .appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw")
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(content.utf8).write(to: target, options: .atomic)
    }

    private static func label(of event: KBCompileProgressEvent) -> String {
        switch event {
        case .started: "started"
        case .preparing: "preparing"
        case .thinking: "thinking"
        case .memorySaved: "memorySaved"
        case .completed: "completed"
        case .error: "error"
        }
    }

    private static func runId(of event: KBCompileProgressEvent) -> UUID {
        switch event {
        case let .started(p): p.runId
        case let .preparing(p): p.runId
        case let .thinking(p): p.runId
        case let .memorySaved(p): p.runId
        case let .completed(p): p.runId
        case let .error(p): p.runId
        }
    }

    // MARK: - Scripted chat-completions transport

    /// Wraps a `tool_calls`-style chat-completions JSON envelope with a
    /// single function call. `argsJSON` is the inner arguments object as a
    /// JSON string (matching OpenAI's wire shape — `arguments` is itself a
    /// JSON-encoded string, not a nested object).
    private static func toolCallTurn(id: String, name: String, argsJSON: String) -> String {
        let escaped = argsJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "id": "stub-tool",
          "model": "stub-model",
          "choices": [{
            "message": {
              "role": "assistant",
              "content": null,
              "tool_calls": [{
                "id": "\(id)",
                "type": "function",
                "function": {"name": "\(name)", "arguments": "\(escaped)"}
              }]
            },
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

// MARK: - Recording publisher

/// Captures every published event in order so the suite can assert
/// ordering. Actor isolation gives us automatic thread-safety on the
/// `events` array; the protocol's `publish(_:tenantID:)` is `async` so
/// actor isolation satisfies the requirement cleanly.
actor RecordingProgressPublisher: KBCompileProgressPublisher {
    private var events: [KBCompileProgressEvent] = []

    func publish(_ event: KBCompileProgressEvent, tenantID _: UUID) async {
        events.append(event)
    }

    func snapshot() -> [KBCompileProgressEvent] {
        events
    }
}

// MARK: - Scripted / throwing transports

/// `HermesChatTransport` that returns canned response bodies in order, one
/// per `chatCompletions` call. Raises if the script is exhausted — that
/// signals the agent loop ran more turns than the test scripted.
private actor ScriptedChatTransportInbox {
    private var turns: [String]
    init(turns: [String]) {
        self.turns = turns
    }

    func next() throws -> String {
        guard !turns.isEmpty else { throw ScriptedChatTransportError.exhausted }
        return turns.removeFirst()
    }
}

private enum ScriptedChatTransportError: Error { case exhausted }

private struct ScriptedChatTransport: HermesChatTransport {
    let inbox: ScriptedChatTransportInbox

    init(turns: [String]) {
        inbox = ScriptedChatTransportInbox(turns: turns)
    }

    func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        let body = try await inbox.next()
        return Data(body.utf8)
    }

    func chatCompletionsWithMetadata(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> HermesChatTransportMetadata {
        let body = try await inbox.next()
        return HermesChatTransportMetadata(data: Data(body.utf8), headers: [:])
    }
}

/// `HermesChatTransport` that always throws. Used to drive the error path.
private struct ThrowingChatTransport: HermesChatTransport {
    func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        throw HTTPError(.badGateway, message: "scripted transport failure")
    }

    func chatCompletionsWithMetadata(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> HermesChatTransportMetadata {
        throw HTTPError(.badGateway, message: "scripted transport failure")
    }
}
