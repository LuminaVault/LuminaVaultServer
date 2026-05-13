# GeminiContentsAdapter Plan (HER-199)

## Goal
Add a `GeminiContentsAdapter` that implements `ProviderAdapter` to route LLM requests to Google Gemini's `generateContent` v1beta API. Enables Gemini 2.5 Pro (2M token context) and Gemini 2.5 Flash as routing targets.

## Current Context
- `ProviderKind` enum already has `.gemini` case — no change needed
- `ProviderAdapter` protocol exists in `Sources/App/LLM/Routing/ProviderAdapter.swift` — just implement it
- `HermesGatewayAdapter` is the only existing implementation — use as structural reference
- Payloads arrive as OpenAI chat-completions JSON shape; adapters must translate to/from provider format
- `ProviderError` already covers transient/permanent/network error classification
- `App+build.swift` already registers `HermesGatewayAdapter` in `ProviderRegistry` — need to add Gemini

## Payload Translation Requirements

### OpenAI → Gemini (request)
| OpenAI | Gemini |
|--------|--------|
| `messages[]` with roles: user/assistant/system | `contents[]` with roles: user/model (no system role) |
| `system` role messages | Fold into `system_instruction` OR prepend to first user message |
| `tools[].function.name/parameters` | `tools[].function_declarations[].name/parameters` |
| `tool_calls[].id/function/name/arguments` | `parts[].functionCall.name/args` |
| `messages[]` with role: "tool" | `parts[].functionResponse.name/response` |

### Gemini → OpenAI (response)
| Gemini | OpenAI |
|--------|--------|
| `candidates[].content.parts[].text` | `choices[].message.content` |
| `candidates[].content.parts[].functionCall` | `choices[].message.tool_calls[].function` |
| `usageMetadata` | `usage` (map token counts) |
| `finishReason` (STOP/MAX_TOKENS/etc) | `choices[].finish_reason` (stop/length/etc) |

## Proposed Approach
1. Create `GeminiContentsAdapter` struct implementing `ProviderAdapter`
2. Add Gemini API key config to `ServiceContainer` and env reading
3. Register adapter in `App+build.swift` ProviderRegistry
4. Unit tests for payload translation + round-trip
5. Integration test via existing `RoutedLLMTransportTests`

## Step-by-Step Plan

### Step 1: Add Gemini config to ServiceContainer
**File:** `Sources/App/App+build.swift`

Add `geminiAPIKey: String` to `ServiceContainer` init. Read from env:
```swift
geminiAPIKey: reader.string(forKey: "gemini.apiKey", default: ""),
```

### Step 2: Create GeminiContentsAdapter
**New file:** `Sources/App/LLM/Routing/GeminiContentsAdapter.swift`

Struct implements `ProviderAdapter`:
- `kind: ProviderKind = .gemini`
- `baseURL: URL` (fixed: `https://generativelanguage.googleapis.com/v1beta/models/`)
- `apiKey: String`
- `session: URLSession`
- `logger: Logger`

**`chatCompletions(payload:profileUsername:)` implementation:**
1. Parse OpenAI JSON payload
2. Translate `messages[]` → `contents[]` (user→user, assistant→model, system→system_instruction)
3. Translate `tools[]` → `tools[].function_declarations[]`
4. Translate `tool` role messages → `functionResponse` parts
5. Build Gemini JSON body
6. POST to `{baseURL}{model}:generateContent?key={apiKey}`
7. Parse Gemini response → OpenAI-shaped JSON → return as `Data`
8. Map HTTP errors to `ProviderError` (follow same pattern as HermesGatewayAdapter)

**Key translation details:**
- System messages: use `system_instruction` field (Gemini native) rather than folding into first user message — preserves semantic intent
- Multi-turn: maintain ordering; Gemini `contents[]` preserves conversation history
- Tool calls: Gemini `functionCall` parts sit inside content parts, not as separate messages
- Tool results: Gemini `functionResponse` parts match by function name
- Model extraction: parse `model` field from payload, support `gemini-2.5-pro`, `gemini-2.5-flash`, or fallback to configured default

### Step 3: Register in App+build.swift
**File:** `Sources/App/App+build.swift` (lines ~353-361)

Add conditional registration when API key is non-empty:
```swift
var adapters: [any ProviderAdapter] = [
    HermesGatewayAdapter(baseURL: hermesURL, session: .shared, logger: routingLogger),
]
if !services.geminiAPIKey.isEmpty {
    adapters.append(GeminiContentsAdapter(
        apiKey: services.geminiAPIKey,
        session: .shared,
        logger: routingLogger,
    ))
}
let providerRegistry = ProviderRegistry(adapters: adapters, logger: routingLogger)
```

### Step 4: Error Classification
Follow `HermesGatewayAdapter` pattern:
- 429 → `ProviderError.transient` (rate limit, retryable)
- 5xx → `ProviderError.transient` (upstream error, retryable)
- 4xx (except 429) → `ProviderError.permanent` (bad payload, not retryable)
- Network errors → `ProviderError.network`

Gemini-specific errors to classify:
- `RESOURCE_EXHAUSTED` (429) → transient
- `INVALID_ARGUMENT` (400) → permanent
- `UNAVAILABLE` (503) → transient
- `DEADLINE_EXCEEDED` (504) → transient

### Step 5: Tests
**New file:** `Tests/AppTests/LLM/Routing/GeminiContentsAdapterTests.swift`

Test cases:
1. Simple user message → correct Gemini `contents[]` shape
2. Multi-turn conversation with system message → `system_instruction` + alternating user/model
3. Tool definitions → `tools[].function_declarations[]`
4. Tool call response → `functionCall` part structure
5. Tool result message → `functionResponse` part structure
6. Gemini response parsing → OpenAI-shaped JSON with content
7. Gemini functionCall response → `tool_calls[]` in OpenAI shape
8. Error classification (429, 500, 400)
9. Round-trip: OpenAI payload → Gemini request → mock Gemini response → OpenAI response

### Step 6: Acceptance Validation
Same round-trip test pattern as `AnthropicMessagesAdapter` ticket:
1. Send OpenAI-shaped request to adapter
2. Verify Gemini API receives correct shape (mock or real)
3. Verify adapter returns OpenAI-shaped response
4. Confirm 2M-token request doesn't exceed Gemini's chunked-upload boundary
5. Test long-context skill (daily-brief over full vault) end-to-end via Gemini Pro

## Files Likely to Change
- `Sources/App/App+build.swift` — add gemini config + register adapter
- `Sources/App/LLM/Routing/GeminiContentsAdapter.swift` — NEW
- `Tests/AppTests/LLM/Routing/GeminiContentsAdapterTests.swift` — NEW

## Risks & Tradeoffs
- **API key security**: Gemini key stored in env var (like other providers). No issue since API is cloud-reachable (not user-local).
- **2M token boundary**: Gemini's chunked upload may have limits — need to verify payload size handling.
- **Model name mapping**: Client may send `gemini-2.5-pro` but Gemini API expects full model name like `gemini-2.5-pro-latest` — consider adding a mapping layer.
- **System message handling**: Gemini's `system_instruction` is separate from `contents[]` — must verify this works with tool calls (some Gemini versions restrict system_instruction + tools combinations).

## Open Questions
- Should model name mapping support aliases (e.g., `gemini-pro` → `gemini-2.5-pro-latest`)?
- Is there a per-user proxy consideration? (Gemini is cloud-reachable, so single API key works server-side — no per-user proxying needed.)
