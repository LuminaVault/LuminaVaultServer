# HER-183 — HermesMemoryService send X-Hermes-Session-Key, not X-Hermes-Profile

Linear: https://linear.app/luminavault/issue/HER-183
Branch: `fernandocorreia316/her-183-hermesmemoryservice-send-x-hermes-session-key-not-x-hermes`

## Problem

Every server → Hermes gateway HTTP call sends header `X-Hermes-Profile: <username>`. The Hermes gateway (`gateway/platforms/api_server.py`) documents only:

- `X-Hermes-Session-Id` — opt-in conversation continuity
- `X-Hermes-Session-Key` — opt-in long-term memory scoping (per-tenant)

`X-Hermes-Profile` is silently ignored. Gateway returns 200, traffic collapses to whatever default profile the gateway picked. Per-user memory scoping is broken in production.

## Goal

1. Every Hermes call sends `X-Hermes-Session-Key: <tenant-uuid>` (User.id UUID string).
2. Every Hermes call with a real conversation context also sends `X-Hermes-Session-Id: <conversation-id>`. One-shot tool calls (memory upsert, KB compile, memo gen) omit it.
3. Zero call sites reference `X-Hermes-Profile` after this lands.
4. Tests assert both headers' presence and values.
5. End-to-end: two distinct users hitting `/v1/llm/chat` produce isolated memory scopes in the Hermes gateway.

## Scope decisions (confirmed with user)

- **Session-Id**: include in this PR (option "Include Session-Id now"). One-shot internal callers pass `nil`; chat-completions endpoint reads it from a new optional `ChatRequest.sessionID` field.
- **Rename**: full rename `profileUsername: String` → `sessionKey: String` across the transport / adapter / service chain. Callers swap `user.username` → `user.id.uuidString`.

## Affected files

### LuminaVaultShared (DTOs, must bump first per CLAUDE.md §3)

- `Sources/LuminaVaultShared/APIDTOs.swift` — add `sessionID: String?` to `ChatRequest` (optional, defaults nil — backwards-compatible).

### LuminaVaultServer — Sources

Transport / adapter layer (rename param + header swap):

- `Sources/App/LLM/HermesLLMService.swift:13` — protocol `chat(profileUsername:request:)` → `chat(sessionKey:sessionID:request:)`.
- `Sources/App/LLM/HermesLLMService.swift:47–56` — `URLSessionHermesLLMService.chat`: set `X-Hermes-Session-Key`; set `X-Hermes-Session-Id` when non-nil. Drop the `X-Hermes-Profile` assumption comment.
- `Sources/App/LLM/HermesLLMStreamService.swift:35,69,101` — stream entrypoint: same rename + header swap on `HTTPClientRequest.headers.add(...)`.
- `Sources/App/LLM/RoutedHermesLLMService.swift:34,59` — forward `sessionKey` + `sessionID` to underlying transport.
- `Sources/App/LLM/Routing/ProviderAdapter.swift:20,21,25,26` — protocol `chatCompletions(payload:profileUsername:)` → `chatCompletions(payload:sessionKey:sessionID:)`. Default impl forwards both.
- `Sources/App/LLM/Routing/HermesGatewayAdapter.swift:35,36,39,58` — set `X-Hermes-Session-Key`; conditional `X-Hermes-Session-Id`.
- `Sources/App/LLM/Routing/OllamaAdapter.swift:39,40` — rename param (header not used; Ollama ignores).
- `Sources/App/LLM/Routing/OpenAICompatibleAdapter.swift:47,48` — rename param (header not used).
- `Sources/App/LLM/Routing/AnthropicAdapter.swift:49,50` — rename param.
- `Sources/App/LLM/Routing/GeminiContentsAdapter.swift:34,35` — rename param.
- `Sources/App/LLM/Routing/RoutedLLMTransport.swift:51,52,55,77` — forward both new params through failover loop.
- `Sources/App/Memory/HermesMemoryService.swift:26,27,28,37,58,62,70,283,295,311,350,367` — `HermesChatTransport` protocol params: `profileUsername` → `sessionKey`, add `sessionID: String?`. `URLSessionHermesChatTransport.chatCompletionsWithMetadata` sets the new headers. `HermesMemoryService.upsert` / `.search` / `.runAgent` take + thread the new params. Callers from memory tooling pass `sessionID: nil`.
- `Sources/App/Memory/FollowUpGenerator.swift:36,66` — rename param, pass `sessionID: nil`.
- `Sources/App/Memory/MemoGeneratorService.swift:159,170,212` — rename + nil session-id.

Callers (replace `user.username` with `try user.requireID().uuidString`):

- `Sources/App/LLM/LLMController.swift:79` — read `finalBody.sessionID` (new field) and pass through.
- `Sources/App/Memory/MemoryController.swift:120,156` — sessionKey = user UUID; sessionID = nil (one-shot upsert/search).
- `Sources/App/Memory/MemoController.swift:26` — sessionKey = user UUID; sessionID = nil.
- `Sources/App/Memory/QueryController.swift:67,83,134,179` — sessionKey = user UUID. The streamed query has a logical conversation; pass `req`-supplied session ID if present, else nil.
- `Sources/App/KB/KBCompileController.swift:34` — sessionKey = user UUID; sessionID = nil.
- `Sources/App/App+build.swift:749` — wiring site: update to new signature; ensure `userID` is threaded.

### Tests

- `Tests/AppTests/Memory/HermesMemoryServiceTests.swift:108` — comment + assertion: header is now `X-Hermes-Session-Key`, value is tenant UUID string (not "alice"). Update transport stub `calls` shape if it stores `profileUsername`.
- `Tests/AppTests/LLM/HermesGatewayAdapterTests.swift:113,197` — `X-Hermes-Profile` → `X-Hermes-Session-Key`. Use UUID-shaped values, assert format. Add a new test asserting `X-Hermes-Session-Id` present-when-set / absent-when-nil.
- Any other test that constructs a transport stub matching the old param name (audit during impl).

### Docs

- `docs/integration.md:426` — update assumption text from `X-Hermes-Profile: <username>` to `X-Hermes-Session-Key: <tenant-uuid>` plus brief mention of optional `X-Hermes-Session-Id`.

## Step-by-step execution

### Step 1 — Shared DTO (bump first)

In `LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift`:

```swift
public struct ChatRequest: Codable, Sendable {
    public let messages: [ChatMessage]
    public let model: String?
    public let temperature: Double?
    public let stream: Bool
    public let tools: [ChatTool]?
    public let tool_choice: AnyJSONValue?
    public let sessionID: String?  // NEW — optional Hermes Session-Id passthrough
    enum CodingKeys: String, CodingKey {
        case messages, model, temperature, stream, tools, tool_choice
        case sessionID = "session_id"
    }
    public init(
        messages: [ChatMessage],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = false,
        tools: [ChatTool]? = nil,
        tool_choice: AnyJSONValue? = nil,
        sessionID: String? = nil
    ) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.stream = stream
        self.tools = tools
        self.tool_choice = tool_choice
        self.sessionID = sessionID
    }
}
```

Default-nil keeps every existing call site source-compatible. Build LuminaVaultShared in isolation, then point LuminaVaultServer at the bumped version.

### Step 2 — ProviderAdapter protocol rename

In `Sources/App/LLM/Routing/ProviderAdapter.swift`:

```swift
public protocol ProviderAdapter: Sendable {
    var kind: ProviderKind { get }
    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data
    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata
}

public extension ProviderAdapter {
    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
        let data = try await chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: sessionID)
        return HermesChatTransportMetadata(data: data, headers: [:])
    }
}
```

### Step 3 — HermesGatewayAdapter

```swift
func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
    // ... existing baseURL/auth resolution ...
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
    if let sessionID, !sessionID.isEmpty {
        req.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
    }
    if let authHeader, !authHeader.isEmpty {
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    req.httpBody = payload
    // ... existing dispatch + error classification ...
}
```

### Step 4 — Other adapters

`OllamaAdapter`, `OpenAICompatibleAdapter`, `AnthropicAdapter`, `GeminiContentsAdapter` — rename param `profileUsername` → `sessionKey`, add `sessionID: String?`, leave bodies alone (they don't use the value). The session metadata is Hermes-specific; non-Hermes providers shouldn't see or leak it.

### Step 5 — RoutedLLMTransport

Forward both fields through the failover loop:

```swift
func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
    // ... candidate iteration ...
    let metadata = try await adapter.chatCompletionsWithMetadata(
        payload: candidatePayload,
        sessionKey: sessionKey,
        sessionID: sessionID,
    )
    // ...
}
```

### Step 6 — HermesLLMService (sync) + stream service

Same shape — rename `profileUsername` → `sessionKey`, add `sessionID: String?`. Set both headers in the URLSession (sync) and HTTPClientRequest (stream) variants.

Drop the stale comment in `HermesLLMService.swift:54–55`:

```
// ASSUMPTION: upstream Hermes gateway routes per-profile traffic via this header.
// If wrong, swap to `model: "<username>/<base>"` or `?profile=` here.
```

That assumption was wrong; HER-183 closes it. Replace with a one-liner pointing at the Hermes gateway header doc if useful, else no comment.

### Step 7 — HermesMemoryService

Protocol `HermesChatTransport` — `profileUsername` → `sessionKey`, add `sessionID: String?`. `URLSessionHermesChatTransport.chatCompletionsWithMetadata` writes both headers (Session-Id conditional). `HermesMemoryService.upsert(tenantID:profileUsername:...)` → `upsert(tenantID:sessionKey:sessionID:...)`. Same for `.search`. Internal `runAgent` threads both. Tool dispatch unchanged.

### Step 8 — FollowUpGenerator + MemoGeneratorService

Rename param. Pass `sessionID: nil` — neither is a continuation of a user-visible chat thread.

### Step 9 — Controllers

Each caller computes `let sessionKey = try user.requireID().uuidString` once near the top, then passes it everywhere `user.username` used to go. `sessionID`:

- `LLMController.chat` — `finalBody.sessionID` (new optional ChatRequest field).
- `MemoryController.upsert`, `.search` — nil.
- `MemoController` — nil.
- `QueryController.query` + streamed variant — nil for now (no thread ID on the route yet; can backfill in a follow-up).
- `KBCompileController` — nil.

### Step 10 — Tests

`HermesMemoryServiceTests`:
- Capture-transport stub stores `sessionKey` (and optionally `sessionID`) instead of `profileUsername`. If the stub type isn't exported elsewhere, update inline.
- The "alice" assertion becomes `tenantID.uuidString`.
- Add a sibling test: search call also sends the tenant UUID.

`HermesGatewayAdapterTests`:
- Lines 113, 197 — change header name to `X-Hermes-Session-Key`. Values switch from `"alice"` / `"bob"` to a stable test UUID (e.g., declared as `static let aliceID = UUID(uuidString: "00000000-0000-0000-0000-000000000A11")!`).
- New test: when `sessionID` is non-nil, `X-Hermes-Session-Id` is set; when nil, header is absent. Existing `nil`-sessionID cases assert header absence.

Run `swift test --filter Hermes` first for fast feedback; full `swift test` before commit.

### Step 11 — Docs

`docs/integration.md:426`:

```
The `X-Hermes-Session-Key: <tenant-uuid>` header scopes long-term memory
per LuminaVault user (User.id UUID string). For chat endpoints with a
conversation context, the server also sends `X-Hermes-Session-Id:
<conversation-id>` to enable Hermes session continuity. Both headers are
documented by Hermes' `gateway/platforms/api_server.py`. The legacy
`X-Hermes-Profile` header was removed in HER-183 — Hermes silently
ignored it, which collapsed all users into the gateway default profile.
```

(Refine to match existing prose style.)

### Step 12 — Verify

```bash
swiftformat --lint .
swift build
swift test
grep -rn 'X-Hermes-Profile\|profileUsername' Sources Tests docs   # expect 0
```

End-to-end smoke (optional manual): two `curl /v1/llm/chat` calls with two different bearer tokens, watch Hermes logs for distinct `Session-Key` values.

### Step 13 — Commit + PR

Per CLAUDE.md §2: this PR does not touch `openapi.yaml` (no contract shape change — Session-Id is a server-internal passthrough on chat) unless we decide to expose `session_id` in the chat request body publicly. **Decision: expose it.** The shared DTO carries it, and clients (including the iOS app) need a stable schema. Update `Sources/AppAPI/openapi.yaml` `ChatRequest` schema to include `session_id?: string`, then `make bruno-regen`. Commit openapi + bruno in same diff per project rule.

Single commit (or 2: shared DTO + openapi together, then server impl — reviewer-friendly). PR title:

> HER-183: send X-Hermes-Session-Key (tenant UUID) + optional X-Hermes-Session-Id

PR body links Linear ticket, describes blast radius (~25 call sites renamed, 4 transport impls header-swapped), notes that the legacy header was silently ignored (no production behavior to roll back to).

## Risks / non-goals

- **Risk**: failing to update LuminaVaultShared first means LuminaVaultServer build fails on `ChatRequest.sessionID`. Bump shared → server in that order.
- **Risk**: existing iOS clients sending no `session_id` field — handled by the field being optional with a Codable default of nil.
- **Risk**: Hermes gateway needs to be confirmed accepting `X-Hermes-Session-Key` in current deployment. Verify in staging logs before merge to prod.
- **Non-goal**: thread-/conversation-ID generation server-side. The shared DTO accepts a client-supplied value; the server doesn't synthesize one. A follow-up ticket can add a `Conversation` model with a stable UUID if we need server-managed continuity later.
- **Non-goal**: removing `profileUsername` from non-Hermes provider adapter implementations beyond the rename — they ignore the value, but the protocol shape stays consistent across providers.

## Done when

- `swift build` green ✅ (verified 2026-05-23).
- `swiftformat --lint .` clean.
- `grep -rn 'X-Hermes-Profile' Sources Tests docs` returns nothing.
- `grep -rn 'profileUsername' Sources Tests` only matches APNS-display use in SkillRunner / CronScheduler (intentional — those pass a username for push notification body, never for the Hermes header).
- openapi.yaml + bruno collection regenerated.
- PR open against `main`, linked to HER-183.

## Shared prerequisite

`LuminaVaultShared` HEAD adds `ChatRequest.sessionID` + `QueryRequest.sessionID`. Server build needs Shared ≥ 0.30.0 (current tag is 0.29.0). Two-step release:

1. Land a Shared PR with the two DTO additions, cut tag `v0.30.0`.
2. Server PR bumps `.package(url: ..., from: "0.30.0")` and removes the dev-cycle path override.

During development this worktree uses `.package(path: "../../../../LuminaVaultShared")` so local Shared edits compile in. Revert that line before opening the server PR.

## Pre-existing tech debt surfaced (not part of HER-183)

Pulling Shared HEAD via path override exposes a duplicate `UserTier` enum (one in `Sources/App/Billing/EntitlementChecker.swift`, one in shared HER-185 work). Test target fails to build for `EnforcementTests`. Documented in memory observation 7162. Out of scope for HER-183 — file follow-up to delete the server-local copy after Shared 0.30.0 is consumed.
