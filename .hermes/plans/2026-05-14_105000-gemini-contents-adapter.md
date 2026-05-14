# GeminiContentsAdapter Plan (HER-199)

## Goal
Add a `GeminiContentsAdapter` that implements `ProviderAdapter` to route LLM requests to Google Gemini's `generateContent` v1beta API. Enables Gemini 2.5 Pro (2M token context) and Gemini 2.5 Flash as routing targets.

Also wire the routed transport into the user-facing `/v1/llm/chat` endpoint (HER-200) so users can actually select a model via the `model` field.

## Current Context
- `ProviderKind` enum already had `.gemini` case — no change needed.
- `DefaultHermesLLMService` called the Hermes gateway directly, bypassing the routing infrastructure.
- Replaced with `RoutedHermesLLMService` so the `model` field now flows through `RoutedLLMTransport → ProviderAdapter`.
- Added `RoutingModelRouter` — routes `gemini*` models to `.gemini`, everything else to `.hermesGateway`.

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
1. Create `GeminiContentsAdapter` struct implementing `ProviderAdapter` ✅
2. Add Gemini API key config to `ServiceContainer` and env reading ✅
3. Register adapter in `App+build.swift` ProviderRegistry ✅
4. Wire `RoutedHermesLLMService` in place of `DefaultHermesLLMService` (HER-200) ✅
5. Add `RoutingModelRouter` to route by model name (HER-200) ✅
6. Add full tool_calls/tools support to DTOs ✅
7. Unit tests for routing + payload translation ✅

## Step-by-Step Plan

### Step 1: Add Gemini config to ServiceContainer ✅
**File:** `Sources/App/App+build.swift` + `Sources/App/Services/ServiceContainer.swift`
- Added `geminiAPIKey: String` to `ServiceContainer`
- Reads from `gemini.apiKey` env/config key

### Step 2: Create GeminiContentsAdapter ✅
**New file:** `Sources/App/LLM/Routing/GeminiContentsAdapter.swift`

Implements `ProviderAdapter`:
- Parses OpenAI JSON payload
- Translates messages → Gemini contents[] + system_instruction
- Translates tools → function_declarations
- Translates tool_calls/functionResponses
- POSTs to `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={apiKey}`
- Translates Gemini response → OpenAI-shaped JSON
- Error classification: 429 → transient, 5xx → transient, 4xx → permanent

Key decisions:
- Uses `system_instruction` for system messages (Gemini native field)
- Model name resolution: aliases like `gemini-pro` → `gemini-2.5-pro`
- `_callId` stored as metadata in functionCall parts for round-trip

### Step 3: Register in App+build.swift ✅
- Conditional registration when `services.geminiAPIKey` is non-empty
- Preserves existing Hermes adapter as the default

### Step 4: Wire RoutedHermesLLMService (HER-200) ✅
**New file:** `Sources/App/LLM/RoutedHermesLLMService.swift`
- Replaces `DefaultHermesLLMService` in `App+build.swift`
- Uses `RoutedLLMTransport` under the hood
- Proper OpenAI wire-format encodable types (OutboundMessage, OutboundTool, etc.)

### Step 5: Add RoutingModelRouter (HER-200) ✅
**File:** `Sources/App/LLM/Routing/ModelRouter.swift`
- Routes `gemini*` model hints → `.gemini` with `.hermesGateway` fallback
- Routes everything else → `.hermesGateway`
- Case-insensitive matching

### Step 6: DTO updates ✅
**File:** `Sources/App/LLM/LLMDTOs.swift`
- Added `tool_calls` field to `ChatMessage`
- Added `tools`, `tool_choice`, `stream` fields to `ChatRequest`
- Added `AnyJSONValue` enum for arbitrary JSON Schema parameters
- All DTOs now conform to `Sendable`
- Inbound → Outbound conversion methods (`toOutbound()`)

### Step 7: Tests ✅
- `RoutingModelRouterTests.swift` — 9 tests covering all routing cases
- All existing LLM/domain tests pass (21 tests across 4 suites)

## Files Changed
1. `Sources/App/LLM/Routing/GeminiContentsAdapter.swift` — NEW
2. `Sources/App/LLM/Routing/ModelRouter.swift` — appended RoutingModelRouter struct
3. `Sources/App/LLM/RoutedHermesLLMService.swift` — NEW (replaces DefaultHermesLLMService wiring)
4. `Sources/App/LLM/LLMDTOs.swift` — Rewritten: full tools/tool_calls support, AnyJSONValue, Sendable
5. `Sources/App/Services/ServiceContainer.swift` — Added geminiAPIKey field
6. `Sources/App/App+build.swift` — gemini config + RoutedHermesLLMService + RoutingModelRouter wiring
7. `Tests/AppTests/LLM/Routing/RoutingModelRouterTests.swift` — NEW
8. `Tests/AppTests/Services/APNSNotificationServiceTests.swift` — Updated ChatMessage construction

## OpenAI → Gemini Translation (implemented in GeminiContentsAdapter)
- `messages[]` → `contents[]` with role mapping (user→user, assistant→model)
- `system` messages → `system_instruction` field
- `tools[]` → `tools[].function_declarations[]`
- `tool_calls[]` → functionCall parts in content
- `role: "tool"` → functionResponse parts
- `temperature`, `max_tokens` → `generationConfig`
- Response mapping: text→content, functionCall→tool_calls, usageMetadata→usage, finishReason mapping

## Build status
✅ swift build clean
✅ swift test (routing + LLM domain: 30 tests pass)

## Risks & Tradeoffs
- **API key security**: Gemini key stored in env var (same pattern as other providers). No issue since API is cloud-reachable.
- **2M token boundary**: Gemini's chunked upload may have limits — needs real-world verification.
- **system_instruction + tools**: Some Gemini versions restrict combining system_instruction with tools; this may need a fallback to folding system into first user message if errors occur.
- **DefaultHermesLLMService**: Kept as a file but no longer wired in App+build.swift. Can be revived for dev/testing if needed.
