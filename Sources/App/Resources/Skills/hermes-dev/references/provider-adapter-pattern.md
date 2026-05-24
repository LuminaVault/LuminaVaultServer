# Provider Adapter Pattern — Adding LLM Providers to LuminaVaultServer

When adding a new LLM upstream (Gemini, OpenAI, Anthropic, etc.) to the routed dispatcher, follow this pattern.

## Architecture overview

```
User request (POST /v1/llm/chat)
  → LLMController → RoutedHermesLLMService
    → RoutedLLMTransport
      → ModelRouter → picks ProviderKind
        → ProviderRegistry → resolves ProviderAdapter
          → [GeminiContentsAdapter / HermesGatewayAdapter / etc.]
            → External API
```

## Five-step checklist

### 1. Confirm `ProviderKind` exists
`Sources/App/LLM/Routing/ProviderKind.swift` already has `.gemini`, `.openai`, `.anthropic`, etc. If your provider case is missing, add it there first. Cases are stable on the wire — do NOT rename existing ones.

### 2. Implement `ProviderAdapter`
Create `Sources/App/LLM/Routing/<ProviderName>Adapter.swift`:

```swift
struct YourAdapter: ProviderAdapter {
    let kind: ProviderKind = .yourCase
    private let apiKey: String
    private let session: URLSession
    private let logger: Logger

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername).data
    }

    func chatCompletionsWithMetadata(payload: Data, profileUsername: String) async throws -> HermesChatTransportMetadata {
        // 1. Parse OpenAI-shaped JSON from `payload`
        // 2. Translate to provider-native format
        // 3. POST to provider endpoint
        // 4. Translate response back to OpenAI shape
        // 5. Classify errors: ProviderError.transient/permanent/network
    }
}
```

**Error classification rules** (inherited from `ProviderError`):
- `.transient` (429, 5xx) → failover to next candidate
- `.network` → failover to next candidate  
- `.permanent` (4xx except 429) → STOP, bubble up (our payload is wrong)

### 3. Add config to `ServiceContainer`
Add the new credential to `Sources/App/Services/ServiceContainer.swift` (e.g. `geminiAPIKey: String`), then read it in `App+build.swift`:

```swift
geminiAPIKey: reader.string(forKey: "gemini.apiKey", default: ""),
```

### 4. Register in `App+build.swift` (conditional on credentials)
```swift
var providerAdapters: [any ProviderAdapter] = [
    HermesGatewayAdapter(baseURL: hermesURL, session: .shared, logger: routingLogger),
]
if !services.geminiAPIKey.isEmpty {
    providerAdapters.append(GeminiContentsAdapter(
        apiKey: services.geminiAPIKey, session: .shared, logger: routingLogger))
}
let providerRegistry = ProviderRegistry(adapters: providerAdapters, logger: routingLogger)
```

### 5. Wire the routed service to user-facing endpoint
The user-facing `POST /v1/llm/chat` must use `RoutedHermesLLMService` (backed by `RoutedLLMTransport`), NOT `DefaultHermesLLMService` (bypasses routing entirely):

```swift
let modelRouter: any ModelRouter = RoutingModelRouter()
let routedTransport = RoutedLLMTransport(registry: providerRegistry, router: modelRouter, logger: routingLogger)
let llmService = RoutedHermesLLMService(transport: routedTransport, defaultModel: services.hermesDefaultModel, logger: Logger(label: "lv.llm"))
```

## Model routing

`RoutingModelRouter` (in `ModelRouter.swift`) routes based on the `model` field:
- `gemini-*` → `.gemini` primary, `.hermesGateway` fallback
- Everything else → `.hermesGateway` primary

## Common pitfalls

### Type name collisions across files
**Problem**: Defining `OpenAIToolFunction` or `AnyEncodable` in multiple `.swift` files causes "ambiguous for type lookup" errors at compile time.

**Fix**: Consolidate ALL DTO types (`ChatMessage`, `ChatRequest`, `HermesUpstreamResponse`, `OutboundMessage`, `AnyEncodable`, `AnyJSONValue`, etc.) into a single file (`LLMDTOs.swift`). Adapter files should only contain translation logic, never type definitions.

### `ChatMessage` struct changes break all call sites
**Problem**: Adding a non-optional property to `ChatMessage` (e.g. `tool_calls`) requires every `ChatMessage(...)` call site to include it.

**Fix**: Always make new properties optional with a default value, OR update all references immediately. Test compilation after each DTO change.

### Gemini `system_instruction` vs tool calls
Gemini v1beta has a known limitation: `system_instruction` may not work alongside `tools` in some model versions. If tool-using Gemini requests fail, fall back to folding system messages into the first user message content.

### 2M token boundary
Gemini 2.5 Pro supports 2M tokens but the chunked upload boundary must be respected. For very large payloads, the adapter should handle the streaming/generateContent boundary gracefully.

### Concurrency requirements for DTOs
**Problem**: `capture of 'body' with non-Sendable type 'ChatRequest' in a '@Sendable' closure` errors in `LLMController`.

**Fix**: All DTOs passed through the async pipeline (`ChatRequest`, `ChatMessage`, `ChatResponse`) must conform to `Sendable`.
```swift
struct ChatRequest: Codable, Sendable { ... }
```
When updating these structs, ensure all properties are either value types (String, Int) or explicitly `Sendable` reference types. Arrays and Dictionaries of `Sendable` values are implicitly `Sendable` in Swift 5.10+.