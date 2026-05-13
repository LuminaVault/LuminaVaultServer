# DTO Migration Plan: LuminaVaultServer → LuminaVaultShared

## Goal
Migrate all API contract types (requests, responses, DTOs) shared between the LuminaVaultServer (Hummingbird) and the iOS SwiftUI client into the `LuminaVaultShared` package, so both platforms consume a single source of truth.

## Current Context
- `LuminaVaultShared` is already a package dependency (line 24 of Package.swift)
- Server imports it as `.product(name: "LuminaVaultShared", package: "LuminaVaultShared")`
- Hummingbird types (`ResponseEncodable`) are **marker protocols only** — they add no fields or behavior
- 37 types across 20 files conform to `ResponseEncodable`
- Several DTOs have server-only convenience initializers (`init(_ memory: Memory)`, `init(_ space: Space)`, `init(_ row: VaultFile)`, `init(_ outcome: HealthCorrelationOutcome)`)
- Admin DTOs (`MemoryAdmin*`, `HealthAdmin*`, `HermesProfile*Conformance`) are server-only and should NOT migrate

## Approach
The **split-conformance pattern** — already used in `WebAuthnService.swift`:

```swift
// LuminaVaultShared (no Hummingbird dependency):
struct AuthResponse: Codable { ... }

// Server-side extension:
import Hummingbird
extension AuthResponse: ResponseEncodable {}
```

This requires zero changes to the shared types themselves — just moving them and stripping `ResponseEncodable` from their inline conformance.

## Decision Matrix

### Migrate to Shared (client needs these) ✅
| Type | Source File | Dependencies | Notes |
|------|-------------|--------------|-------|
| `RegisterRequest` | AuthDTOs.swift | pure Codable | |
| `LoginRequest` | AuthDTOs.swift | pure Codable | |
| `RefreshRequest` | AuthDTOs.swift | pure Codable | |
| `AuthResponse` | AuthDTOs.swift | UUID, String, Int | all Foundation |
| `MFAVerifyRequest` | AuthDTOs.swift | pure Codable | |
| `MFAResendRequest` | AuthDTOs.swift | pure Codable | |
| `OAuthExchangeRequest` | AuthDTOs.swift | pure Codable | |
| `ForgotPasswordRequest` | AuthDTOs.swift | pure Codable | |
| `ResetPasswordRequest` | AuthDTOs.swift | pure Codable | |
| `SendVerificationRequest` | AuthDTOs.swift | pure Codable | |
| `ConfirmEmailRequest` | AuthDTOs.swift | pure Codable | |
| `MeResponse` | AuthDTOs.swift | UUID, String, Bool | all Foundation |
| `UpdatePrivacyRequest` | AuthDTOs.swift | pure Codable | |
| `ChatMessage` | LLMDTOs.swift | ChatToolCall | |
| `ChatToolCall` | LLMDTOs.swift | ChatToolCallFunction | |
| `ChatToolCallFunction` | LLMDTOs.swift | pure Codable | |
| `ChatTool` | LLMDTOs.swift | ChatToolDefinition | |
| `ChatToolDefinition` | LLMDTOs.swift | AnyCodableDict | |
| `ChatRequest` | LLMDTOs.swift | ChatMessage, ChatTool, AnyJSONValue | |
| `ChatResponse` | LLMDTOs.swift | ChatMessage, HermesUpstreamResponse | |
| `HermesUpstreamChoice` | LLMDTOs.swift | ChatMessage | |
| `HermesUpstreamUsage` | LLMDTOs.swift | pure Codable | |
| `HermesUpstreamResponse` | LLMDTOs.swift | HermesUpstreamChoice, HermesUpstreamUsage | |
| `AnyJSONValue` | LLMDTOs.swift | pure Codable | |
| `AnyCodableDict` | LLMDTOs.swift | typealias of AnyJSONValue | |
| `MemoryUpsertResponse` | MemoryController.swift | UUID, String | |
| `MemorySearchRequest` | MemoryController.swift | pure Codable | |
| `MemorySearchResponse` | MemoryController.swift | MemorySearchHitDTO | need to check DTO |
| `MemorySearchHitDTO` | MemoryController.swift | pure Codable | need to verify |
| `MemoryDTO` | MemoryController.swift | **init(_ memory: Memory)** — strip init, keep struct | |
| `MemoryListResponse` | MemoryController.swift | MemoryDTO | |
| `MemoryPatchRequest` | MemoryController.swift | pure Codable | |
| `MemoryLineageResponse` | MemoryController.swift | MemoryLineageSourceDTO | need to check DTO |
| `MemoryLineageSourceDTO` | MemoryController.swift | pure Codable | need to verify |
| `MemoResponse` | MemoController.swift | UUID, String | |
| `QueryResponse` | QueryController.swift | QueryHitDTO | need to check DTO |
| `QueryHitDTO` | QueryController.swift | pure Codable | need to verify |
| `SpaceDTO` | SpacesController.swift | **init(_ space: Space)** — strip init, keep struct | |
| `SpaceListResponse` | SpacesController.swift | SpaceDTO | |
| `SpaceCreateRequest` | SpacesController.swift | pure Codable | |
| `VaultUploadResponse` | VaultController.swift | String, Int | |
| `VaultFileDTO` | VaultController.swift | **init(_ row: VaultFile)** — strip init, keep struct | |
| `VaultFileListResponse` | VaultController.swift | VaultFileDTO | |
| `VaultMoveRequest` | VaultController.swift | pure Codable | |
| `DeviceRegistrationRequest` | DeviceController.swift | pure Codable | need to verify |
| `DeviceRegistrationResponse` | DeviceController.swift | UUID, String | |
| `OnboardingStateDTO` | OnboardingController.swift | Date, Bool | all Foundation |
| `KBCompileResponse` | KBCompileController.swift | KBCompileWrittenFile, KBCompileMemoryRef | |
| `KBCompileWrittenFile` | KBCompileController.swift | pure Codable | |
| `KBCompileMemoryRef` | KBCompileController.swift | pure Codable | |
| `AchievementsListResponse` | AchievementsController.swift | SubDTO, ArchetypeDTO | nested types too |
| `AchievementsRecentResponse` | AchievementsController.swift | UnlockDTO | nested type too |
| `SoulResponse` | SoulController.swift | String, Int | |
| `PhoneStartResponse` | PhoneAuthController.swift | UUID, Date | |
| `PhoneVerifyRequest` | PhoneAuthController.swift | pure Codable | |
| `EmailMagicStartResponse` | EmailMagicLinkController.swift | UUID, Date | |
| `EmailMagicVerifyRequest` | EmailMagicLinkController.swift | pure Codable | |
| `HealthIngestResponse` | HealthIngestController.swift | HealthIngestedRef | |
| `HealthIngestedRef` | HealthIngestController.swift | pure Codable | |
| `GetResponse` | HermesConfigController.swift | Date, String, Bool | |
| `PutRequest` | HermesConfigController.swift | pure Codable | |
| `TestResponse` | HermesConfigController.swift | Date | |

### Stay in Server (not client-facing) 🚫
| Type | Reason |
|------|--------|
| `WebAuthnBeginRegistrationResponse` | WebAuthn protocol — client uses Passkeys API, not raw response shape |
| `WebAuthnFinishRegistrationResponse` | Same |
| `WebAuthnBeginAuthenticationResponse` | Same |
| `MemoryPruningSweepSummary` | Admin internal |
| `MemoryPruneResult` | Admin internal |
| `MemoryRecomputeResponse` | Admin endpoint — not for client |
| `HealthCorrelationSweepSummary` | Admin internal |
| `HealthCorrelationRunResponse` | Admin endpoint; depends on `HealthCorrelationOutcome` enum |
| `HermesProfileReconcileSummary` | Admin internal |
| `HermesProfileReapSummary` | Admin internal |
| `HermesProfileHealth` | Admin internal |
| `OutboundMessage`, `OutboundTool`, etc. | Internal routing wire format, never sent to client |
| `toOutbound()` extensions | Server-only conversion logic |

## Step-by-Step Plan

### Phase 1: Prepare LuminaVaultShared

**File to create in LuminaVaultShared repo:**
```
Sources/LuminaVaultShared/API/
├── AuthDTOs.swift
├── ChatDTOs.swift
├── MemoryDTOs.swift
├── MemoDTOs.swift
├── QueryDTOs.swift
├── SpaceDTOs.swift
├── VaultDTOs.swift
├── DeviceDTOs.swift
├── OnboardingDTOs.swift
├── KBCompileDTOs.swift
├── AchievementsDTOs.swift
├── SoulDTOs.swift
├── PhoneAuthDTOs.swift
├── EmailMagicAuthDTOs.swift
├── HealthIngestDTOs.swift
└── HermesConfigDTOs.swift
```

Each file contains only `Codable` types with **no `import Hummingbird`** and **no `ResponseEncodable` conformance**.

### Phase 2: Update LuminaVaultServer

For each source file that moved DTOs:
1. Remove the struct definitions (they now live in Shared)
2. Remove `ResponseEncodable` from any remaining inline conformances
3. Add `import LuminaVaultShared` 
4. Add `extension <type>: ResponseEncodable {}` lines to restore the Hummingbird conformance
5. Strip server-only `init(_ model:)` initializers from DTOs — move them to a private server extension if still needed

### Phase 3: Update LuminaVaultServer Package.swift
- Already has LuminaVaultShared dependency ✅
- No changes needed

### Phase 4: Update iOS Client
- Remove local DTO copies (if any exist)
- Import/depend on LuminaVaultShared
- Update references to use shared types

### Phase 5: Server ResponseEncodable Registry

Create a single file in the server that registers all shared types:

```swift
// Sources/App/Shared/SharedResponseEncodable.swift
import Hummingbird
import LuminaVaultShared

extension AuthResponse: ResponseEncodable {}
extension MeResponse: ResponseEncodable {}
extension ChatResponse: ResponseEncodable {}
extension MemoryUpsertResponse: ResponseEncodable {}
extension MemoryDTO: ResponseEncodable {}
// ... all 37 types
```

### Phase 6: Build & Test
- `swift build` in LuminaVaultServer
- `swift test` — confirm no regressions
- Build iOS client with new shared types

## Files That Will Change (LuminaVaultServer)

| File | Change |
|------|--------|
| `Sources/App/Auth/DTOs/AuthDTOs.swift` | Remove migrated structs; add `import LuminaVaultShared`; add `ResponseEncodable` extensions |
| `Sources/App/LLM/LLMDTOs.swift` | Remove migrated structs (chat, AnyJSON, HermesUpstream); add `import LuminaVaultShared`; add extensions; **keep** Outbound* types and `toOutbound()` methods |
| `Sources/App/Memory/MemoryController.swift` | Remove MemoryUpserResponse, MemorySearchRequest/Response/HitDTO, MemoryDTO, MemoryListResponse, MemoryPatchRequest, MemoryLineageResponse/SourceDTO; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Memory/MemoController.swift` | Remove MemoResponse; add `import LuminaVaultShared`; add extension |
| `Sources/App/Memory/QueryController.swift` | Remove QueryResponse, QueryHitDTO; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Spaces/SpacesController.swift` | Remove SpaceDTO, SpaceListResponse, SpaceCreateRequest; add `import LuminaVaultShared`; add extensions; **strip or relocate** `init(_ space: Space)` |
| `Sources/App/Vault/VaultController.swift` | Remove VaultUploadResponse, VaultFileDTO, VaultFileListResponse, VaultMoveRequest; add `import LuminaVaultShared`; add extensions; **strip or relocate** `init(_ row: VaultFile)` |
| `Sources/App/Devices/DeviceController.swift` | Remove DeviceRegistrationRequest, DeviceRegistrationResponse; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Onboarding/OnboardingController.swift` | Remove OnboardingStateDTO; add `import LuminaVaultShared`; add extension |
| `Sources/App/KB/KBCompileController.swift` | Remove KBCompileResponse, KBCompileWrittenFile, KBCompileMemoryRef; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Achievements/AchievementsController.swift` | Remove AchievementsListResponse (+ nested types), AchievementsRecentResponse (+ nested types); add `import LuminaVaultShared`; add extensions |
| `Sources/App/Auth/SoulController.swift` | Remove SoulResponse; add `import LuminaVaultShared`; add extension |
| `Sources/App/Auth/Phone/PhoneAuthController.swift` | Remove PhoneStartResponse, PhoneVerifyRequest; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Auth/EmailMagicLink/EmailMagicLinkController.swift` | Remove EmailMagicStartResponse, EmailMagicVerifyRequest; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Health/HealthIngestController.swift` | Remove HealthIngestResponse, HealthIngestedRef; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Settings/HermesConfigController.swift` | Remove GetResponse, PutRequest, TestResponse; add `import LuminaVaultShared`; add extensions |
| `Sources/App/Shared/SharedResponseEncodable.swift` | **NEW** — all ResponseEncodable conformances for shared types |
| `Tests/AppTests/**/*.swift` | Update any `import Hummingbird` → `import LuminaVaultShared` where they reference moved types (likely no changes needed since tests import App which re-exports) |

## Risks & Tradeoffs

1. **`init(_ memory: Memory)` style initializers** — These tie the DTO to the Fluent `Memory` model. They must be moved to a server-side extension (`extension MemoryDTO { init(_ memory: Memory) throws { ... } }`) rather than living in the shared package.
2. **`HealthCorrelationOutcome` enum** — This is a server-only type used by `HealthCorrelationRunResponse`. Since this is an admin endpoint, the response stays server-side and doesn't migrate.
3. **Nested DTOs** (`AchievementsListResponse.SubDTO`, etc.) — Must be extracted to top-level shared types or restructured.
4. **iOS build pipeline** — After pushing the shared package tag, the iOS project needs to update its SPM dependency to point at the new tag.
5. **Breaking change if iOS uses old DTO shapes** — If the iOS client has diverged from server DTOs, migrating to shared will surface mismatches at compile time. This is desirable but needs coordination.

## Effort Estimate
- **Phase 1-3 (server work):** 2-3 hours — mostly mechanical move + conformances
- **Phase 4 (iOS integration):** depends on iOS project complexity; ~30 min to point SPM at new tag if no shape divergences
- **Phase 5 (testing):** 1 hour — full build + test cycle

## Open Questions
1. Does the iOS client currently have its own copies of these DTOs, or does it already import LuminaVaultShared for some of them?
2. Are DTOs with Fluent model initializers (`init(_ memory:)`) used in tests? If so, the server-side extensions need to remain accessible.
3. Should `HealthIngestedRef` also migrate if the iOS client sends health data?
