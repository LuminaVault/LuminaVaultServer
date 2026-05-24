# HER-288 — kb-compile WebSocket progress events

**Status:** design approved, awaiting plan
**Tracks:** [HER-288](https://linear.app/luminavault/issue/HER-288) — server side of [HER-108](https://linear.app/luminavault/issue/HER-108)
**Related:** HER-13 (`/v1/ws`), HER-8 (`kb-compile`), HER-290 (memory review-state, separate spec)

## Goal

Surface live progress of `POST /v1/kb-compile` over the existing per-tenant `/v1/ws` broadcast channel so the iOS client (HER-108) can render "Reading…", "Thinking…", "Saved memory X" microcopy + a glowing scroll instead of a stopwatch spinner.

## Non-goals

- `pendingMemoryIds` / memory review fields — owned by HER-290.
- Per-file `.reading(fileId, current, total)` events — see *Reality check* below.
- Replacing the sync HTTP response with a job-submit/poll handshake — keep current contract; WS is additive.

## Reality check vs original ticket wording

The original HER-288 acceptance proposed `.reading` + `.distilling` per-file events. Reading `KBCompileService.runCompileLoop` shows this isn't feasible without re-architecting compile: the service dumps every file block into one prompt, and the LLM emits `memory_upsert` tool calls in whatever order it chooses. There is no per-file iteration on the server.

**Revised event taxonomy** (approved):

| Event | When | Payload |
|---|---|---|
| `.started` | Before LLM call, after row resolution | `runId`, `totalFiles` |
| `.preparing` | After `writeVaultFiles`, before first model token | `runId` |
| `.thinking` | Each iteration of the tool-use loop entered | `runId`, `iteration` |
| `.memorySaved` | Each `memory_upsert` dispatch success | `runId`, `memory: MemoryDTO` |
| `.completed` | Right before HTTP 200 returns | `runId`, `response: KBCompileResponse` |
| `.error` | On any thrown error before completion | `runId`, `message` |

Sequencing guarantee: `.started` is always first; `.completed` xor `.error` is always last. `.memorySaved` fires strictly after the underlying `MemoryRepository.create` commits.

## Wire format

Each event is a JSON text frame on `/v1/ws`, top-level `{type, payload}`. Mirrors the existing `QueryStreamEvent` pattern in `LuminaVaultShared/APIDTOs.swift`.

```json
{"type":"started","payload":{"runId":"…","totalFiles":12}}
{"type":"preparing","payload":{"runId":"…"}}
{"type":"thinking","payload":{"runId":"…","iteration":1}}
{"type":"memorySaved","payload":{"runId":"…","memory":{"id":"…","content":"…",…}}}
{"type":"completed","payload":{"runId":"…","response":{"memoriesIngested":5,"memoriesUpdated":null,"durationMs":4123,"runId":"…"}}}
```

`type` value uses `lowerCamel` (matches `QueryStreamEvent.followUps`). Payload size kept well under the `WebSocketBroadcastGuard.maxMessageBytes` (16 KB) discipline even though server-originating frames bypass the inbound guard.

## DTO additions (`LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift`)

```swift
public struct KBCompileStartedDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let totalFiles: Int
}

public struct KBCompilePreparingDTO: Codable, Sendable, Equatable {
    public let runId: UUID
}

public struct KBCompileThinkingDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let iteration: Int
}

public struct KBCompileMemorySavedDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let memory: MemoryDTO
}

public struct KBCompileCompletedDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let response: KBCompileResponse
}

public struct KBCompileErrorDTO: Codable, Sendable, Equatable {
    public let runId: UUID
    public let message: String
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
        case memorySaved = "memorySaved"
        case completed, error
    }
    // init(from:) + encode(to:) match QueryStreamEvent's manual codable.
}
```

`KBCompileResponse` gains a `runId: UUID` field (additive; clients that miss WS still correlate). `MemoryDTO` is untouched.

## Server architecture

```
KBCompileProgressPublisher (protocol, Sendable)
└── func publish(_ event: KBCompileProgressEvent, tenantID: UUID) async

WebSocketKBCompileProgressPublisher
├── inject ConnectionManager (default .shared)
└── JSON encode → ConnectionManager.broadcast(tenantID:, message:)

NoopKBCompileProgressPublisher (tests + when WS not wired)
```

- `KBCompileService.init` gains `publisher: any KBCompileProgressPublisher` (defaulted to noop for callers that don't care).
- `KBCompileController.compile`:
  1. Generates `let runId = UUID()` immediately after row resolution.
  2. Emits `.started(runId:, totalFiles: rows.count)` before invoking service. (Empty-rows short-circuit still returns with `runId` echoed but no progress events.)
  3. Calls service with `runId`. Service emits `.preparing`, `.thinking` per iteration, `.memorySaved` from `dispatch` on each successful upsert.
  4. On service return, controller emits `.completed(runId:, response:)`.
  5. On thrown error, controller emits `.error(runId:, message:)` then rethrows.
- Publish failures **never** throw — wrapped in `try?` with a warning log. Compile must succeed even when WS infra is sick.

## Wiring

- `App+build.swift`: construct `WebSocketKBCompileProgressPublisher(connectionManager: connectionManager)`, pass to `KBCompileService`.
- Tests: pass `NoopKBCompileProgressPublisher()` or a `RecordingKBCompileProgressPublisher` that appends to an array for ordering assertions.

## openapi.yaml

Add components-only schemas (no path entry — WS messages aren't formalized in OpenAPI 3.0):

- `KBCompileProgressEvent` (object w/ `type` + `payload`, description naming the variants)
- `KBCompileStartedDTO`, `KBCompilePreparingDTO`, `KBCompileThinkingDTO`, `KBCompileMemorySavedDTO`, `KBCompileCompletedDTO`, `KBCompileErrorDTO`
- `KBCompileResponse` updated to include `runId: { type: string, format: uuid }` (required).

Bruno collection regenerated via `make bruno-regen`.

## Test plan

1. **Unit** — `KBCompileProgressEventCodableTests`: round-trip every case, assert wire shape matches docs above.
2. **Unit** — `KBCompileServiceProgressTests`: inject a `RecordingPublisher`, run a fake transport that emits two `memory_upsert` calls and a final reply; assert ordering `[started, preparing, thinking, thinking, memorySaved, memorySaved, thinking, completed]`. (Iteration count depends on tool-use loop turn count.)
3. **Unit** — error path: transport throws after one `memory_upsert`; assert ordering ends with `.error`.
4. **Integration** — `WebSocketKBCompileProgressPublisherTests`: stub `ConnectionManager`, assert JSON envelope shape and tenant routing.
5. **E2E** (existing Bruno + manual): connect WS, POST kb-compile, assert WS frames arrive in order. Optional follow-up — automated E2E via the existing WS test harness.

## Risk register

- **Risk:** Old clients receive new `runId` field on `KBCompileResponse`. **Mitigation:** `runId` is required (non-optional) — a Swift Codable additive non-optional only breaks old clients on encode, not decode. Since `KBCompileResponse` is server-encoded and client-decoded, ignoring an unknown key is the default Swift Codable behavior, so existing clients tolerate the new field. Bump `LuminaVaultShared` minor version so the iOS client + tests recompile against the new shape.
- **Risk:** WS broadcast latency vs compile completion: client receives `.completed` after HTTP 200 lands. **Mitigation:** Controller publishes `.completed` **before** returning HTTP response. Same actor sequencing as `.started`.
- **Risk:** Multi-device fan-out (phone + Mac) — both receive every event. Acceptable / desired.
- **Risk:** Empty-rows short-circuit emits no events. **Mitigation:** Still emit `.started(totalFiles: 0)` + `.completed` so clients see a clean cycle and can render "nothing to learn".

## Out-of-scope deferrals tracked

- Pending memory review state — HER-290.
- Pending file count for button disable — HER-293.
- iOS WS client subscription, confetti, memory list UI — HER-108.
