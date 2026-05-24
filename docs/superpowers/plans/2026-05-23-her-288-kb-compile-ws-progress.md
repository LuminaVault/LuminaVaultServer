# HER-288 kb-compile WebSocket Progress Events — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish kb-compile run progress over the existing `/v1/ws` per-tenant channel so HER-108's iOS client can render live "Reading… / Thinking… / Saved memory X" status while the LLM extracts memories.

**Architecture:** Tagged Codable enum `KBCompileProgressEvent` in `LuminaVaultShared` mirroring the existing `QueryStreamEvent` pattern. New `KBCompileProgressPublisher` protocol with `WebSocket…` + `Noop…` implementations. Publisher injected into `KBCompileService`; controller generates a `runId` and emits start/complete/error around the service call. Publish failures swallowed; HTTP path unaffected.

**Tech Stack:** Swift 6.3, Hummingbird, FluentKit, HummingbirdWebSocket, swift-log, swift-testing (existing test framework — confirm in step 3).

---

## Spec

See `docs/superpowers/specs/2026-05-23-her-288-kb-compile-ws-progress-design.md` (committed in `b3d01b2`).

## File Structure

**LuminaVaultShared** (`../LuminaVaultShared/`):

- Modify: `Sources/LuminaVaultShared/APIDTOs.swift` — add 6 payload DTOs, `KBCompileProgressEvent` enum, `runId` field on `KBCompileResponse`.
- Create: `Tests/LuminaVaultSharedTests/KBCompileProgressEventTests.swift` — Codable round-trip per case.

**LuminaVaultServer** (this repo):

- Create: `Sources/App/KB/KBCompileProgressPublisher.swift` — protocol + Noop + WebSocket implementations.
- Modify: `Sources/App/KB/KBCompileService.swift` — accept publisher in init; emit `.preparing`, `.thinking`, `.memorySaved`.
- Modify: `Sources/App/KB/KBCompileController.swift` — generate `runId`; emit `.started`, `.completed`, `.error`; pass `runId` into service + `KBCompileResponse`.
- Modify: `Sources/App/App+build.swift` — construct `WebSocketKBCompileProgressPublisher` and pass to `KBCompileService`.
- Modify: `Sources/AppAPI/openapi.yaml` — add component schemas; update `KBCompileResponse`.
- Create: `Tests/AppTests/KB/KBCompileProgressPublisherTests.swift` — WS publisher JSON shape + routing.
- Create: `Tests/AppTests/KB/KBCompileProgressServiceTests.swift` — recording publisher ordering assertions.
- Modify: `Tests/AppTests/KB/KBCompileControllerTests.swift` — assert `runId` in response + `.started`/`.completed` emitted.

---

## Task 1: Shared payload DTOs + runId on KBCompileResponse

**Files:**
- Modify: `../LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift` — insert after the existing `KBCompileResponse` block (find via `grep -n "public struct KBCompileResponse" Sources/LuminaVaultShared/APIDTOs.swift`).

- [ ] **Step 1: Read the existing KBCompileRequest/KBCompileResponse + QueryStreamEvent blocks**

Run: `grep -n -A 20 "public struct KBCompileResponse\|public enum QueryStreamEvent" ../LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift`

Expected: find both blocks. Confirm `KBCompileResponse` currently has `memoriesIngested`, `memoriesUpdated`, `durationMs`.

- [ ] **Step 2: Add `runId` to `KBCompileResponse`**

Open `../LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift`. Replace the existing struct with:

```swift
public struct KBCompileResponse: Codable, Sendable, Equatable {
    public let memoriesIngested: Int
    public let memoriesUpdated: Int?
    public let durationMs: Int?
    public let runId: UUID
    public init(memoriesIngested: Int, memoriesUpdated: Int?, durationMs: Int?, runId: UUID) {
        self.memoriesIngested = memoriesIngested
        self.memoriesUpdated = memoriesUpdated
        self.durationMs = durationMs
        self.runId = runId
    }
}
```

Notes:
- `runId` is non-optional. Server-encoded only; iOS decoders ignore unknown keys by default so older clients tolerate it. Bump `LuminaVaultShared` minor version (see Task 12).
- If the existing initializer is referenced by tests, those callers will need updating (Task 11).

- [ ] **Step 3: Append payload DTOs immediately after `KBCompileResponse`**

```swift
// MARK: - kb-compile progress (HER-288)

public struct KBCompileStartedDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let totalFiles: Int
    public init(runId: UUID, totalFiles: Int) {
        self.runId = runId
        self.totalFiles = totalFiles
    }
}

public struct KBCompilePreparingDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public init(runId: UUID) { self.runId = runId }
}

public struct KBCompileThinkingDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let iteration: Int
    public init(runId: UUID, iteration: Int) {
        self.runId = runId
        self.iteration = iteration
    }
}

public struct KBCompileMemorySavedDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let memory: MemoryDTO
    public init(runId: UUID, memory: MemoryDTO) {
        self.runId = runId
        self.memory = memory
    }
}

public struct KBCompileCompletedDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let response: KBCompileResponse
    public init(runId: UUID, response: KBCompileResponse) {
        self.runId = runId
        self.response = response
    }
}

public struct KBCompileErrorDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let message: String
    public init(runId: UUID, message: String) {
        self.runId = runId
        self.message = message
    }
}

public enum KBCompileProgressEvent: Codable, Sendable, Equatable {
    case started(KBCompileStartedDTO)
    case preparing(KBCompilePreparingDTO)
    case thinking(KBCompileThinkingDTO)
    case memorySaved(KBCompileMemorySavedDTO)
    case completed(KBCompileCompletedDTO)
    case error(KBCompileErrorDTO)

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum EventType: String, Codable {
        case started, preparing, thinking
        case memorySaved
        case completed, error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(EventType.self, forKey: .type)
        switch type {
        case .started:
            self = .started(try c.decode(KBCompileStartedDTO.self, forKey: .payload))
        case .preparing:
            self = .preparing(try c.decode(KBCompilePreparingDTO.self, forKey: .payload))
        case .thinking:
            self = .thinking(try c.decode(KBCompileThinkingDTO.self, forKey: .payload))
        case .memorySaved:
            self = .memorySaved(try c.decode(KBCompileMemorySavedDTO.self, forKey: .payload))
        case .completed:
            self = .completed(try c.decode(KBCompileCompletedDTO.self, forKey: .payload))
        case .error:
            self = .error(try c.decode(KBCompileErrorDTO.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .started(let p):
            try c.encode(EventType.started, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .preparing(let p):
            try c.encode(EventType.preparing, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .thinking(let p):
            try c.encode(EventType.thinking, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .memorySaved(let p):
            try c.encode(EventType.memorySaved, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .completed(let p):
            try c.encode(EventType.completed, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .error(let p):
            try c.encode(EventType.error, forKey: .type)
            try c.encode(p, forKey: .payload)
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
cd ../LuminaVaultShared
git add Sources/LuminaVaultShared/APIDTOs.swift
git commit -m "HER-288: add KBCompileProgressEvent + payload DTOs + runId on KBCompileResponse

Tagged Codable enum mirroring QueryStreamEvent pattern. runId is the
correlation handle between WS events and the final HTTP response.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Shared Codable round-trip tests

**Files:**
- Create: `../LuminaVaultShared/Tests/LuminaVaultSharedTests/KBCompileProgressEventTests.swift`

- [ ] **Step 1: Check existing test framework**

Run: `head -5 ../LuminaVaultShared/Tests/LuminaVaultSharedTests/*.swift | head -20`

Expected: see `import Testing` or `import XCTest`. Use whichever the existing tests use (this repo uses swift-testing per swift-tools-version 6.3 — confirm).

- [ ] **Step 2: Write failing tests for all 6 cases**

Using `swift-testing` (`@Test` / `#expect`):

```swift
import Foundation
import Testing
@testable import LuminaVaultShared

@Suite("KBCompileProgressEvent Codable")
struct KBCompileProgressEventTests {
    private let runId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func roundTrip(_ event: KBCompileProgressEvent) throws -> KBCompileProgressEvent {
        let data = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(KBCompileProgressEvent.self, from: data)
    }

    @Test func startedRoundTrip() throws {
        let original: KBCompileProgressEvent = .started(.init(runId: runId, totalFiles: 12))
        #expect(try roundTrip(original) == original)
    }

    @Test func preparingRoundTrip() throws {
        let original: KBCompileProgressEvent = .preparing(.init(runId: runId))
        #expect(try roundTrip(original) == original)
    }

    @Test func thinkingRoundTrip() throws {
        let original: KBCompileProgressEvent = .thinking(.init(runId: runId, iteration: 3))
        #expect(try roundTrip(original) == original)
    }

    @Test func memorySavedRoundTrip() throws {
        let memory = MemoryDTO(
            id: UUID(),
            content: "user prefers dark mode",
            tags: nil,
            score: nil,
            accessCount: nil,
            queryHitCount: nil,
            lastAccessedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            sourceVaultFileId: nil
        )
        let original: KBCompileProgressEvent = .memorySaved(.init(runId: runId, memory: memory))
        #expect(try roundTrip(original) == original)
    }

    @Test func completedRoundTrip() throws {
        let response = KBCompileResponse(
            memoriesIngested: 5,
            memoriesUpdated: nil,
            durationMs: 4123,
            runId: runId
        )
        let original: KBCompileProgressEvent = .completed(.init(runId: runId, response: response))
        #expect(try roundTrip(original) == original)
    }

    @Test func errorRoundTrip() throws {
        let original: KBCompileProgressEvent = .error(.init(runId: runId, message: "transport failed"))
        #expect(try roundTrip(original) == original)
    }

    @Test func wireEnvelopeShape() throws {
        let event: KBCompileProgressEvent = .started(.init(runId: runId, totalFiles: 0))
        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "started")
        #expect(json["payload"] is [String: Any])
    }
}
```

> **Note:** confirm `MemoryDTO`'s init signature in `APIDTOs.swift` before pasting — adjust the parameter list to match the exact existing initializer.

- [ ] **Step 3: Run the tests; expect them to pass**

Run: `cd ../LuminaVaultShared && swift test --filter KBCompileProgressEvent`

Expected: 7 passing tests.

If they fail, the failure is in Task 1's enum implementation, not the tests — go fix Task 1.

- [ ] **Step 4: Commit**

```bash
cd ../LuminaVaultShared
git add Tests/LuminaVaultSharedTests/KBCompileProgressEventTests.swift
git commit -m "HER-288: round-trip tests for KBCompileProgressEvent cases

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Publisher protocol + Noop + WebSocket impls

**Files:**
- Create: `Sources/App/KB/KBCompileProgressPublisher.swift`

- [ ] **Step 1: Write the publisher file**

```swift
import Foundation
import Logging
import LuminaVaultShared

/// HER-288 — fan-out of kb-compile progress events to whatever transport
/// the deployment wires up. The default production impl emits to the
/// per-tenant /v1/ws broadcast channel; tests use Noop or a recording
/// publisher.
public protocol KBCompileProgressPublisher: Sendable {
    func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async
}

/// Drops every event. Used in unit tests that don't care about WS, and as
/// a safety default when no concrete publisher is wired.
public struct NoopKBCompileProgressPublisher: KBCompileProgressPublisher {
    public init() {}
    public func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async {}
}

/// Encodes the event as JSON text and broadcasts to all of the tenant's
/// open WS connections via `ConnectionManager`. Encode/transport failures
/// are logged at warning level and swallowed — a sick WS path must never
/// break kb-compile.
public struct WebSocketKBCompileProgressPublisher: KBCompileProgressPublisher {
    private let connectionManager: ConnectionManager
    private let logger: Logger
    private let encoder: JSONEncoder

    public init(connectionManager: ConnectionManager, logger: Logger) {
        self.connectionManager = connectionManager
        self.logger = logger
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async {
        do {
            let data = try encoder.encode(event)
            guard let message = String(data: data, encoding: .utf8) else {
                logger.warning("kb-compile progress encode produced non-utf8 bytes", metadata: [
                    "tenant_id": .string(tenantID.uuidString),
                ])
                return
            }
            await connectionManager.broadcast(tenantID: tenantID.uuidString, message: message)
        } catch {
            logger.warning("kb-compile progress publish failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "error": .string("\(error)"),
            ])
        }
    }
}
```

Note: `ConnectionManager.broadcast` expects `tenantID: String` per its existing signature (`actor ConnectionManager`'s `broadcast(tenantID: String, message: String)`). Convert from UUID at the call site.

- [ ] **Step 2: Confirm the file compiles standalone**

Run: `swift build --target App 2>&1 | tail -20`

Expected: build succeeds. If it fails because `ConnectionManager` is `internal`, change the publisher to `internal` access (drop `public`); the publisher only needs to be visible inside the `App` module. Update the protocol + concrete types to `internal` and re-build.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/KB/KBCompileProgressPublisher.swift
git commit -m "HER-288: KBCompileProgressPublisher protocol + Noop + WebSocket impl

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: WebSocket publisher tests

**Files:**
- Create: `Tests/AppTests/KB/KBCompileProgressPublisherTests.swift`

- [ ] **Step 1: Inspect existing test file style**

Run: `head -25 Tests/AppTests/KB/KBCompileHappyPathTests.swift`

Note the import set + testing framework. Mirror that style in the new file.

- [ ] **Step 2: Write the test file**

```swift
import Foundation
import Logging
import Testing
@testable import App
import LuminaVaultShared

@Suite("WebSocketKBCompileProgressPublisher")
struct KBCompileProgressPublisherTests {
    @Test func publishEncodesEnvelopeAndBroadcasts() async throws {
        let manager = ConnectionManager()
        let tenantID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let publisher = WebSocketKBCompileProgressPublisher(
            connectionManager: manager,
            logger: Logger(label: "test.lv.kb-compile.publisher"),
        )

        // No connections registered → broadcast is a no-op success.
        await publisher.publish(
            .started(.init(runId: tenantID, totalFiles: 7)),
            tenantID: tenantID,
        )

        // Smoke: assert that connection list is empty (broadcast didn't error).
        let connections = await manager.listConnections(tenantID: tenantID.uuidString)
        #expect(connections.isEmpty)
    }

    @Test func encodedShapeIsTaggedEnvelope() throws {
        let event: KBCompileProgressEvent = .preparing(.init(runId: UUID()))
        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "preparing")
        let payload = try #require(json["payload"] as? [String: Any])
        #expect(payload["runId"] is String)
    }
}
```

> **Note on coverage:** asserting the broadcast actually delivered to a fake outbound writer requires a `WebSocketOutboundWriter` mock, which Hummingbird doesn't expose cleanly. The shape assertion + no-throw smoke is sufficient for unit scope; end-to-end delivery is covered by Task 11.

- [ ] **Step 3: Run the tests**

Run: `swift test --filter KBCompileProgressPublisher`

Expected: 2 passing tests.

- [ ] **Step 4: Commit**

```bash
git add Tests/AppTests/KB/KBCompileProgressPublisherTests.swift
git commit -m "HER-288: WS publisher envelope shape + smoke tests

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Inject publisher into KBCompileService

**Files:**
- Modify: `Sources/App/KB/KBCompileService.swift`

- [ ] **Step 1: Read the full service file**

Run: `wc -l Sources/App/KB/KBCompileService.swift` (expect ~400 lines based on prior exploration).

Read the whole file. Identify (a) the `init` parameter list, (b) the `compileExistingVaultFiles` entry point, (c) where the file-write loop happens (look for the `writtenFiles` accumulator), (d) `runCompileLoop`'s iteration boundary (`while`/`for` loop), (e) `dispatch` (the `memory_upsert` tool handler).

- [ ] **Step 2: Add publisher field + init param**

In the `actor KBCompileService` properties, append (after `maxToolIterations: Int`):

```swift
let progress: any KBCompileProgressPublisher
```

In the `init`, append a `progress` parameter with a default of `NoopKBCompileProgressPublisher()`:

```swift
init(
    vaultPaths: VaultPathService,
    transport: any HermesChatTransport,
    memories: MemoryRepository,
    embeddings: any EmbeddingService,
    defaultModel: String,
    logger: Logger,
    maxFileSize: Int = 10 * 1024 * 1024,
    maxBatchBytes: Int = 32 * 1024 * 1024,
    maxToolIterations: Int = 12,
    progress: any KBCompileProgressPublisher = NoopKBCompileProgressPublisher(),
) {
    self.vaultPaths = vaultPaths
    self.transport = transport
    self.memories = memories
    self.embeddings = embeddings
    self.defaultModel = defaultModel
    self.logger = logger
    self.maxFileSize = maxFileSize
    self.maxBatchBytes = maxBatchBytes
    self.maxToolIterations = maxToolIterations
    self.progress = progress
}
```

- [ ] **Step 3: Thread `runId` into `compileExistingVaultFiles`**

Change the signature to accept `runId: UUID`. Update the call inside (which calls `runCompileLoop` — pass `runId` through). The full updated entry point:

```swift
func compileExistingVaultFiles(
    tenantID: UUID,
    profileUsername: String,
    rows: [VaultFile],
    hint: String?,
    runId: UUID,
) async throws -> InternalKBCompileResult {
    // ... existing prelude up to where writeVaultFiles is called ...
    // After file writes succeed, before the LLM call:
    await progress.publish(.preparing(.init(runId: runId)), tenantID: tenantID)

    let summary = try await runCompileLoop(
        tenantID: tenantID,
        profileUsername: profileUsername,
        blocks: compiledTextBlocks,
        hint: hint,
        runId: runId,
    )
    // ... existing tail ...
}
```

> **Implementation note:** the executor must find the existing `writeVaultFiles`-equivalent call (the prior exploration confirmed `writtenFiles` is accumulated before `runCompileLoop`). Place the `.preparing` publish immediately after that write completes. The exact line shifts depending on the current file; read first.

- [ ] **Step 4: Thread `runId` into `runCompileLoop` + emit `.thinking` per iteration**

Update `runCompileLoop` signature to accept `runId: UUID`. Inside the tool-use loop, immediately at the top of each iteration (counter starts at 1), publish `.thinking`:

```swift
private func runCompileLoop(
    tenantID: UUID,
    profileUsername: String,
    blocks: [(path: String, content: String, contentType: String)],
    hint: String?,
    runId: UUID,
) async throws -> CompileSummary {
    let systemPrompt = """..."""  // unchanged

    var conversation: [AgentMessage] = [.init(role: "system", content: systemPrompt)]
    conversation.append(.init(role: "user", content: bundled))

    var collectedMemories: [InternalKBCompileMemoryRef] = []
    var iteration = 0
    for _ in 0..<maxToolIterations {
        iteration += 1
        await progress.publish(.thinking(.init(runId: runId, iteration: iteration)), tenantID: tenantID)

        // ... existing per-iteration code: build payload, call transport,
        //     decode response, handle tool calls via `dispatch(...)`, etc.

        // When dispatching tool calls, pass runId through:
        if let calls = assistant.toolCalls, !calls.isEmpty {
            for call in calls {
                let result = try await dispatch(
                    tenantID: tenantID,
                    toolCall: call,
                    memories: &collectedMemories,
                    runId: runId,
                )
                conversation.append(.init(...))
            }
            continue
        }
        return CompileSummary(text: assistant.content ?? "", memories: collectedMemories)
    }
    // unchanged max-iter throw
}
```

- [ ] **Step 5: Emit `.memorySaved` from `dispatch`**

Update `dispatch` to accept `runId` and publish immediately after the `memories.append(...)` line:

```swift
private func dispatch(
    tenantID: UUID,
    toolCall: ToolCall,
    memories: inout [InternalKBCompileMemoryRef],
    runId: UUID,
) async throws -> String {
    guard toolCall.function.name == "memory_upsert" else {
        return Self.toolErrorJSON("unknown tool \(toolCall.function.name)")
    }
    guard let argsData = toolCall.function.arguments.data(using: .utf8) else {
        return Self.toolErrorJSON("invalid arguments encoding")
    }
    do {
        let args = try JSONDecoder().decode(MemoryUpsertArgs.self, from: argsData)
        let embedding = try await embeddings.embed(args.content)
        let saved = try await self.memories.create(
            tenantID: tenantID,
            content: args.content,
            embedding: embedding,
        )
        let id = try saved.requireID()
        memories.append(InternalKBCompileMemoryRef(id: id, content: saved.content))

        // HER-288 — surface freshly saved memory to WS subscribers. Build the
        // MemoryDTO from the model the repository returned.
        let dto = MemoryDTO(
            id: id,
            content: saved.content,
            tags: nil,
            score: nil,
            accessCount: nil,
            queryHitCount: nil,
            lastAccessedAt: nil,
            createdAt: saved.createdAt,
            updatedAt: saved.updatedAt,
            sourceVaultFileId: nil,
        )
        await progress.publish(.memorySaved(.init(runId: runId, memory: dto)), tenantID: tenantID)

        return Self.encodeJSON(["status": "ok", "id": id.uuidString])
    } catch {
        return Self.toolErrorJSON("memory_upsert failed: \(error)")
    }
}
```

> **MemoryDTO field accuracy:** before pasting, read the actual `MemoryDTO` initializer in `APIDTOs.swift` and the `Memory` Fluent model. Pass the values the model has; leave the rest `nil`. If the model carries `tags` or `sourceVaultFileId`, populate them.

- [ ] **Step 6: Build**

Run: `swift build --target App 2>&1 | tail -30`

Expected: clean build. Compile errors will be from callers that haven't yet been updated to pass `runId` — those are Tasks 7 + 8. For now, if call sites in tests fail to build, comment them out temporarily.

If non-call-site errors appear (e.g., missing import, MemoryDTO init mismatch), fix inline.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/KB/KBCompileService.swift
git commit -m "HER-288: KBCompileService publishes preparing/thinking/memorySaved

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Service ordering tests (recording publisher)

**Files:**
- Create: `Tests/AppTests/KB/KBCompileProgressServiceTests.swift`

- [ ] **Step 1: Read an existing service-level test for the fake transport pattern**

Run: `cat Tests/AppTests/KB/KBCompileHappyPathTests.swift`

Identify the existing `HermesChatTransport` fake the suite uses (likely a struct conforming to the protocol with hard-coded chat-completion responses). The new test will reuse it.

- [ ] **Step 2: Write the recording publisher + ordering tests**

```swift
import Foundation
import Logging
import Testing
@testable import App
import LuminaVaultShared

/// Captures every published event in order for ordering assertions.
final class RecordingProgressPublisher: KBCompileProgressPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [KBCompileProgressEvent] = []
    func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }
    func snapshot() -> [KBCompileProgressEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

@Suite("KBCompileService progress ordering")
struct KBCompileProgressServiceTests {

    @Test func happyPathEmitsPreparingThenThinkingThenMemorySaved() async throws {
        // Reuse the fake transport from KBCompileHappyPathTests — copy its
        // construction here verbatim. It should respond with one tool call
        // (`memory_upsert`) followed by an assistant message containing
        // the final summary string.
        let recorder = RecordingProgressPublisher()
        // let transport = FakeKBCompileTransport(scripted: ...)  // see existing fixture
        // let service = KBCompileService(
        //     vaultPaths: ...,
        //     transport: transport,
        //     memories: ...,
        //     embeddings: DeterministicEmbeddingService(),
        //     defaultModel: "fake",
        //     logger: Logger(label: "test.lv.kb-compile"),
        //     progress: recorder,
        // )

        // Invoke compileExistingVaultFiles with one row + runId.

        let observed = recorder.snapshot()
        let types: [String] = observed.map {
            switch $0 {
            case .started: "started"
            case .preparing: "preparing"
            case .thinking: "thinking"
            case .memorySaved: "memorySaved"
            case .completed: "completed"
            case .error: "error"
            }
        }
        #expect(types.first == "preparing")
        #expect(types.contains("thinking"))
        #expect(types.contains("memorySaved"))
        // .started and .completed are emitted by the controller, not the service.
    }

    @Test func errorPathBubblesUpAndServiceEmitsNoCompletion() async throws {
        // Construct a transport that throws on chatCompletions. The service
        // should rethrow; the recorder should have at most preparing + thinking,
        // never a completed.
        let recorder = RecordingProgressPublisher()
        // ... construct service with throwing transport ...
        // ... invoke + assert it throws ...
        let observed = recorder.snapshot()
        #expect(!observed.contains(where: { if case .completed = $0 { true } else { false } }))
        #expect(!observed.contains(where: { if case .error = $0 { true } else { false } }))
    }
}
```

> **Note:** the suite is intentionally written against a fake transport defined in the existing `KBCompileHappyPathTests`. Lift or duplicate that fake here verbatim — duplication is acceptable since the existing fake is a test-only fixture. If the existing fake transport isn't lift-able, write a minimal scripted `HermesChatTransport` in this file.

- [ ] **Step 3: Run the tests**

Run: `swift test --filter KBCompileProgressService`

Expected: both pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/AppTests/KB/KBCompileProgressServiceTests.swift
git commit -m "HER-288: ordering assertions on service-emitted progress events

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Controller — runId, .started, .completed, .error

**Files:**
- Modify: `Sources/App/KB/KBCompileController.swift`

- [ ] **Step 1: Read the current controller**

Run: `cat Sources/App/KB/KBCompileController.swift` (full file is short, ~80 lines).

- [ ] **Step 2: Add publisher + update compile handler**

```swift
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

struct KBCompileController {
    let service: KBCompileService
    let fluent: Fluent
    let achievements: AchievementsService?
    let progress: any KBCompileProgressPublisher
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: compile)
    }

    @Sendable
    func compile(_ req: Request, ctx: AppRequestContext) async throws -> KBCompileResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: KBCompileRequest.self, context: ctx)

        let runId = UUID()
        let rows = try await resolveRows(tenantID: tenantID, body: body)

        await progress.publish(
            .started(.init(runId: runId, totalFiles: rows.count)),
            tenantID: tenantID,
        )

        guard !rows.isEmpty else {
            let empty = KBCompileResponse(memoriesIngested: 0, memoriesUpdated: 0, durationMs: 0, runId: runId)
            await progress.publish(.completed(.init(runId: runId, response: empty)), tenantID: tenantID)
            return empty
        }

        do {
            let started = ContinuousClock.now
            let result = try await service.compileExistingVaultFiles(
                tenantID: tenantID,
                profileUsername: user.username,
                rows: rows,
                hint: nil,
                runId: runId,
            )
            let elapsed = ContinuousClock.now - started
            let elapsedMs = Int(
                elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000,
            )

            try await markFirstKBCompileCompleted(tenantID: tenantID)

            if let achievements {
                Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .kbCompiled) }
            }

            let response = KBCompileResponse(
                memoriesIngested: result.memories.count,
                memoriesUpdated: nil,
                durationMs: elapsedMs,
                runId: runId,
            )
            await progress.publish(.completed(.init(runId: runId, response: response)), tenantID: tenantID)
            return response
        } catch {
            await progress.publish(
                .error(.init(runId: runId, message: "\(error)")),
                tenantID: tenantID,
            )
            throw error
        }
    }

    private func resolveRows(tenantID: UUID, body: KBCompileRequest) async throws -> [VaultFile] {
        let db = fluent.db()
        if let ids = body.vaultFileIds, !ids.isEmpty {
            return try await VaultFile.query(on: db, tenantID: tenantID)
                .filter(\.$id ~~ ids)
                .all()
        }
        if body.forceFullRecompile {
            return try await VaultFile.query(on: db, tenantID: tenantID).all()
        }
        return try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$processedAt == nil)
            .all()
    }

    private func markFirstKBCompileCompleted(tenantID: UUID) async throws {
        let db = fluent.db()
        guard let row = try await OnboardingState.query(on: db, tenantID: tenantID).first(),
              !row.firstKBCompileCompleted
        else { return }
        row.firstKBCompileCompleted = true
        row.firstKBCompileCompletedAt = Date()
        try await row.save(on: db)
    }
}

extension KBCompileResponse: ResponseEncodable {}
```

- [ ] **Step 3: Build**

Run: `swift build --target App 2>&1 | tail -20`

Expected: error at the `KBCompileController(...)` construction site in `App+build.swift` (missing `progress:` arg). That's Task 8. Other compile errors are bugs to fix here.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/KB/KBCompileController.swift
git commit -m "HER-288: controller generates runId; emits started/completed/error

Empty-rows short-circuit still emits a clean started → completed cycle
so clients render a no-op state.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Wire publisher into App+build

**Files:**
- Modify: `Sources/App/App+build.swift` around lines 1150-1164 (KBCompileService/Controller construction).

- [ ] **Step 1: Locate the kb-compile service construction**

Run: `grep -n "let kbCompileService = KBCompileService" Sources/App/App+build.swift`

- [ ] **Step 2: Replace the construction block with publisher-aware version**

```swift
// kb-compile (write batch + Hermes learning loop) — protected.
let kbCompileProgressPublisher = WebSocketKBCompileProgressPublisher(
    connectionManager: ConnectionManager.shared,
    logger: Logger(label: "lv.kb-compile.progress"),
)
let kbCompileService = KBCompileService(
    vaultPaths: vaultPaths,
    transport: kbCompileTransportOverride ?? routedTransport,
    memories: MemoryRepository(fluent: services.fluent),
    embeddings: DeterministicEmbeddingService(),
    defaultModel: services.hermesDefaultModel,
    logger: Logger(label: "lv.kb-compile"),
    progress: kbCompileProgressPublisher,
)
let kbCompileController = KBCompileController(
    service: kbCompileService,
    fluent: services.fluent,
    achievements: achievementsService,
    progress: kbCompileProgressPublisher,
    logger: Logger(label: "lv.kb-compile.controller"),
)
```

- [ ] **Step 3: Build the whole project**

Run: `swift build 2>&1 | tail -30`

Expected: clean build for the App target.

If `KBCompileMemoryUpsertTests`, `KBCompileHappyPathTests`, `KBCompileSpaceCountersTests`, or `KBCompileControllerTests` fail to compile because their `compileExistingVaultFiles` call sites don't pass `runId`, fix each call site to add `runId: UUID()` (tests don't care which UUID — just need it present). Same for any test that constructs `KBCompileResponse(memoriesIngested:memoriesUpdated:durationMs:)` — add `runId: UUID()`.

- [ ] **Step 4: Run the full server test suite**

Run: `swift test 2>&1 | tail -40`

Expected: all tests green. If anything in `Tests/AppTests/KB/` fails (other than already-updated test files), update those call sites too.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/App+build.swift Tests/AppTests/KB/
git commit -m "HER-288: wire WebSocket progress publisher into kb-compile services

Compile fixes for existing tests where compileExistingVaultFiles +
KBCompileResponse gained a runId argument.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Update controller tests for runId + emission

**Files:**
- Modify: `Tests/AppTests/KB/KBCompileControllerTests.swift`

- [ ] **Step 1: Read the controller tests**

Run: `cat Tests/AppTests/KB/KBCompileControllerTests.swift`

- [ ] **Step 2: Add a recording-publisher-based assertion**

Add a new `@Test` (alongside the existing tests) that:

```swift
@Test func compileEmitsStartedAndCompletedAroundService() async throws {
    let recorder = RecordingProgressPublisher()
    // Build the controller with `recorder` passed as `progress:` and
    // a fake service that returns one memory. (If the existing tests use
    // a different style for constructing the controller, mirror it but
    // swap the publisher.)

    // ... invoke POST /v1/kb-compile via the existing test harness ...

    let observed = recorder.snapshot()
    let types: [String] = observed.map {
        switch $0 {
        case .started: "started"
        case .preparing: "preparing"
        case .thinking: "thinking"
        case .memorySaved: "memorySaved"
        case .completed: "completed"
        case .error: "error"
        }
    }
    #expect(types.first == "started")
    #expect(types.last == "completed")
}

@Test func responseCarriesRunId() async throws {
    // ... POST /v1/kb-compile, decode response ...
    // #expect(response.runId != UUID()) — i.e. non-zero/well-formed.
    // Confirm the same runId appears in the recorded .started + .completed events.
}
```

> **Reuse:** lift `RecordingProgressPublisher` from `KBCompileProgressServiceTests.swift` (Task 6) — either via a shared test helper file (preferred: `Tests/AppTests/KB/RecordingProgressPublisher.swift`) or duplicate.

- [ ] **Step 3: If duplicating the recorder is the chosen path, extract it to a shared file**

Create `Tests/AppTests/KB/RecordingProgressPublisher.swift` containing the class. Remove the copy in Task 6's file. Re-run both suites.

- [ ] **Step 4: Run the controller tests**

Run: `swift test --filter KBCompileController`

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Tests/AppTests/KB/
git commit -m "HER-288: controller tests cover runId + .started/.completed emission

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: openapi.yaml schemas + Bruno regen

**Files:**
- Modify: `Sources/AppAPI/openapi.yaml`

- [ ] **Step 1: Update KBCompileResponse**

Find the existing block (currently at ~line 3375):

```yaml
KBCompileResponse:
  type: object
  required: [memoriesIngested]
  properties:
    memoriesIngested: { type: integer }
    memoriesUpdated: { type: integer }
    durationMs: { type: integer }
```

Replace with:

```yaml
KBCompileResponse:
  type: object
  required: [memoriesIngested, runId]
  properties:
    memoriesIngested: { type: integer }
    memoriesUpdated: { type: integer }
    durationMs: { type: integer }
    runId:
      type: string
      format: uuid
      description: |
        HER-288 — UUID correlation handle. Same value appears in every
        kb-compile WS progress event (`KBCompileProgressEvent`) emitted
        during this run.
```

- [ ] **Step 2: Append progress event schemas in `components.schemas`**

Add after `KBCompileResponse` (paste verbatim, then run `make bruno-regen`):

```yaml
    KBCompileStartedDTO:
      type: object
      required: [runId, totalFiles]
      properties:
        runId: { type: string, format: uuid }
        totalFiles: { type: integer }

    KBCompilePreparingDTO:
      type: object
      required: [runId]
      properties:
        runId: { type: string, format: uuid }

    KBCompileThinkingDTO:
      type: object
      required: [runId, iteration]
      properties:
        runId: { type: string, format: uuid }
        iteration: { type: integer, minimum: 1 }

    KBCompileMemorySavedDTO:
      type: object
      required: [runId, memory]
      properties:
        runId: { type: string, format: uuid }
        memory: { $ref: '#/components/schemas/MemoryDTO' }

    KBCompileCompletedDTO:
      type: object
      required: [runId, response]
      properties:
        runId: { type: string, format: uuid }
        response: { $ref: '#/components/schemas/KBCompileResponse' }

    KBCompileErrorDTO:
      type: object
      required: [runId, message]
      properties:
        runId: { type: string, format: uuid }
        message: { type: string }

    KBCompileProgressEvent:
      type: object
      description: |
        HER-288 — message sent over `/v1/ws` while a kb-compile run is in
        flight. WebSocket messages aren't formalized in OpenAPI 3.0; this
        component exists for client codegen + contract documentation.
        Server emits one started, one preparing, one or more thinking,
        zero or more memorySaved, then exactly one completed or error.
      required: [type, payload]
      properties:
        type:
          type: string
          enum: [started, preparing, thinking, memorySaved, completed, error]
        payload:
          description: |
            Shape depends on `type` — refer to the corresponding `KBCompile*DTO`.
          oneOf:
            - $ref: '#/components/schemas/KBCompileStartedDTO'
            - $ref: '#/components/schemas/KBCompilePreparingDTO'
            - $ref: '#/components/schemas/KBCompileThinkingDTO'
            - $ref: '#/components/schemas/KBCompileMemorySavedDTO'
            - $ref: '#/components/schemas/KBCompileCompletedDTO'
            - $ref: '#/components/schemas/KBCompileErrorDTO'
```

- [ ] **Step 3: Regenerate Bruno collection**

Run: `make bruno-regen 2>&1 | tail -10`

Expected: "Bruno collection regenerated" (or similar — confirm via `git status LuminaVaultCollection/`).

- [ ] **Step 4: Commit openapi + Bruno output together**

```bash
git add Sources/AppAPI/openapi.yaml LuminaVaultCollection/
git commit -m "HER-288: openapi components for KBCompileProgressEvent + runId

WS message schemas added as components-only — OpenAPI 3.0 doesn't
formalize WS, but client codegen + contract docs benefit from typed
shapes. KBCompileResponse gains required runId field.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: Bump LuminaVaultShared version

**Files:**
- Decide: does this repo tag `LuminaVaultShared` releases? Check with `cd ../LuminaVaultShared && git tag --list | tail -5`.

- [ ] **Step 1: Check tagging convention**

Run: `cd ../LuminaVaultShared && git tag --list | tail -5`

- [ ] **Step 2: Tag the new release after pushing**

If tags exist (e.g., `0.27.0`, `0.28.0`):

```bash
cd ../LuminaVaultShared
git push origin HEAD
NEW_TAG="0.<minor+1>.0"  # decide based on git tag --list
git tag -a "$NEW_TAG" -m "HER-288: KBCompileProgressEvent + runId on KBCompileResponse"
git push origin "$NEW_TAG"
```

If no tags exist, skip this task (consumers track `main` directly).

- [ ] **Step 3: Update consumers**

If iOS client and server pin a specific `LuminaVaultShared` version in their `Package.resolved` / `Package.swift`, update those to the new tag and run `swift package update` in each repo. If they track `main`, no action needed beyond the merge.

---

## Task 12: End-to-end smoke

**Files:** none modified.

- [ ] **Step 1: Boot the server locally**

Run: `cd /Users/fernando_idwell/Projects/ObsidianClaudeBrain/LuminaVaultServer && make dev-up`

Wait for `lv.app started` log line.

- [ ] **Step 2: Connect a test WebSocket client**

From a fresh terminal, with a valid JWT for a test tenant:

```bash
# Use wscat or websocat — install with `brew install websocat` if needed.
JWT="<paste valid tenant JWT here>"
websocat \
  -H "Authorization: Bearer $JWT" \
  ws://localhost:8080/v1/ws
```

Expected: the connection holds open silently.

- [ ] **Step 3: Trigger a kb-compile from another terminal**

```bash
curl -X POST http://localhost:8080/v1/kb-compile \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{}' | jq .
```

Expected:
- HTTP 200 with `{"memoriesIngested":N,"durationMs":M,"runId":"…"}`.
- The websocat terminal prints, in order, JSON envelopes: `started`, `preparing`, one or more `thinking`, zero or more `memorySaved`, `completed` (or `error`).

- [ ] **Step 4: Verify the runId matches**

Confirm the `runId` from the HTTP response equals the `runId` field in every WS event.

- [ ] **Step 5: Stop the server**

Run: `make dev-down`

- [ ] **Step 6: Commit any test artefacts (if added)**

If you wrote a scripted shell smoke into `scripts/smoke-her288.sh`, commit it. Otherwise skip.

---

## Self-review checklist

After completing all tasks, the executor should confirm:

- [ ] Every spec acceptance criterion has a task: started/preparing/thinking/memorySaved/completed/error events ✅ (Tasks 5, 7), publisher protocol ✅ (Task 3), runId in response ✅ (Task 1, Task 7), openapi schemas ✅ (Task 10), Bruno regen ✅ (Task 10), sync HTTP response preserved ✅ (Task 7 retains the existing return path), publish failures swallowed ✅ (Task 3 WS publisher).
- [ ] No `TODO`, `TBD`, or placeholder comments in source files outside the spec's explicit notes.
- [ ] `swift test` (server) and `swift test` (shared) both green.
- [ ] `make bruno-regen` produced no manual diff (Bruno output reflects only the openapi changes).
- [ ] Manual WS smoke (Task 12) showed the event ordering and the runId correlation.

---

## PR + Linear handoff

After the worktree is green:

- Push branch + open PR titled "HER-288: kb-compile WS progress events" with the spec doc linked.
- Move HER-288 to In Review with the PR attached.
- On merge, unblock HER-108 by reviewing whether HER-290 + HER-293 still gate.
