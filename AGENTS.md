# LuminaVaultServer — Agent Instructions

These rules apply to every agent (Claude, Codex, etc.) working in this repo. They are non-negotiable unless the user explicitly overrides them in-session.

## 1. Swift 6 Concurrency

- Target Swift 6 language mode with strict concurrency checking. Do not silence warnings with `@unchecked Sendable` or `nonisolated(unsafe)` unless there is a documented reason in a code comment.
- Prefer structured concurrency: `async let`, `TaskGroup`, `withThrowingTaskGroup`. Avoid detached `Task { ... }` for fire-and-forget work — it loses cancellation and error propagation.
- Use `actor` for shared mutable state. Use `Sendable` types across isolation boundaries. Mark protocol requirements `Sendable` when conformers cross actors.
- Hummingbird/Fluent lifecycle code must shut down via the structured `withTestFluent` helper or `ServiceGroup`. Never use `defer { Task { try? await x.shutdown() } }` — it caused SIGTRAP regressions before (see memory context).
- New types default to `struct` + `Sendable`. Reach for `class` only when reference semantics are required.

## 2. Bruno Collection — Backend Is The Source

- `Sources/AppAPI/openapi.yaml` is the **single source of truth** for the API contract.
- The Bruno collection under `LuminaVaultCollection/LuminaVaultServer/` is **generated**, not authored. Regenerate via `make bruno-regen` (which calls `scripts/generate-bruno.sh`).
- Do not hand-edit generated Bruno `.bru` files. If a request is wrong, fix `openapi.yaml` and regenerate.
- Manual top-level Bruno directories (e.g., custom collections outside `LuminaVaultServer/`) are preserved by the script — leave those alone.
- When adding or changing an endpoint: update `openapi.yaml` first, then run `make bruno-regen`, then commit both in the same change.

## 3. LuminaVaultShared — Single Source for DTOs

- All wire-format DTOs shared between client and server live in `LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift` (the sibling repo).
- Do **not** duplicate DTOs in `LuminaVaultServer` or `LuminaVaultClient`. If a server-only or client-only model is required, name and locate it so the boundary is obvious (e.g., `internal struct ...Row` for DB rows, `...ViewState` for UI-only).
- When adding a new DTO: add it to `LuminaVaultShared` first, bump the shared package, then consume in server + client.
- If you find duplicate DTO definitions, treat it as a bug: consolidate into `LuminaVaultShared` and delete the duplicates.

## How To Apply

- Before opening a PR that touches API shape: confirm `openapi.yaml` updated, `make bruno-regen` run, DTO present in `LuminaVaultShared`.
- Before merging concurrency-sensitive code: build with strict concurrency and ensure no new warnings.

---

<claude-mem-context>
# Memory Context

# [LuminaVaultServer] recent context, 2026-05-13 3:53pm GMT+1

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (16,673t read) | 167,422t work | 90% savings

### May 11, 2026
S170 Scaffold HER-190 (contradiction-detector) and HER-189 (pattern-detector) synthesis skills; evaluate AnyAPI library for LuminaVaultClient adoption (May 11 at 9:29 AM)
S172 Scaffold HER-189 (pattern-detector) and HER-190 (contradiction-detector) skills; verify AnyAPI viability for iOS client (May 11 at 12:43 PM)
S174 Scaffold HER-189 (pattern-detector), HER-190 (contradiction-detector), and HER-197 (BYO Hermes endpoint override); evaluate AnyAPI for iOS client (May 11 at 1:02 PM)
S175 Scaffold HER-189 (pattern-detector), HER-190 (contradiction-detector), HER-197 (BYO Hermes); evaluate AnyAPI for iOS client; verify branch isolation before push (May 11 at 1:08 PM)
S177 Scaffold HER-189/190/197, evaluate AnyAPI, rebase all branches onto updated main, push to origin (May 11 at 1:09 PM)
S179 Scaffold HER-189/190/197, evaluate AnyAPI, rebase all branches, resolve conflicts, merge all PRs to main (May 11 at 1:15 PM)
S183 Status verification of HER-189, HER-190 scaffold, HER-192, HER-196, HER-198 on main branch + AnyAPI evaluation for client dependency (May 11 at 1:22 PM)
S185 HER-190/HER-189 scaffolding + AnyAPI evaluation; pre-work included fixing a pre-existing SMSSenderTests failure before running the full suite (May 11 at 6:03 PM)
1875 6:30p 🔵 LuminaVaultServer Test Suite Baseline: 126 Pass, 1 Failure
1876 " 🔵 SMSSenderTests Failure Root Cause: httpBody Nil Despite .serialized Suite
1878 6:31p 🔵 SMSSenderTests Failure: URLSession Converts httpBody to httpBodyStream Before URLProtocol Intercept
1879 " 🔴 Fixed StubURLProtocol to Reconstitute httpBody from httpBodyStream
1881 " 🔴 SMSSenderTests Now Fully Green: All 5 Tests Pass
1882 6:32p 🔵 TestPostgres.swift Not at Expected Path Tests/AppTests/TestPostgres.swift
1883 " 🔵 LuminaVaultServer Test Harness: Two ConfigReaders, Fixed OTP Pins, No Explicit Fluent Shutdown
S189 Fix unsafe Fluent ORM shutdown pattern in LuminaVaultServer test suite — replaced `defer { Task { try? await fluent.shutdown() } }` with structured `withTestFluent` helper (May 11 at 6:33 PM)
1890 6:39p 🔵 Fluent ORM Lifecycle Pattern in Test Suite
1892 6:42p 🔵 Unsafe Async Shutdown Pattern in MemoryLineageTests
1895 " 🔵 Memory Lineage API Structure and Test Design
1896 6:43p 🔵 Complete Inventory of Unsafe Fluent Shutdown Sites Across Test Suite
1897 " 🔵 Memory Lineage Endpoint Has Four Test Cases Including Tenant Isolation
1898 " 🔵 Test Support Directory Contains Only TestPostgres.swift
1900 6:44p 🔴 Created `withTestFluent` Helper to Fix Racy Fluent Shutdown in Tests
1902 " 🔵 Each Test File Has Its Own Duplicate `openFluent()` Helper
1903 " 🔄 Removed Duplicate `openFluent()` from MemoryLineageTests
1904 " 🔄 Migrated Two MemoryLineageTests Call Sites to `withTestFluent`
1906 " 🔄 MemoryLineageTests.swift Fully Migrated to `withTestFluent`
1907 " 🔄 PhoneAuthFlowTests Migrated to `withTestFluent`
1908 6:45p 🔄 All Unsafe Fluent Shutdown Sites Fully Migrated Across Test Suite
1909 " ✅ Build Succeeds After `withTestFluent` Refactor
1910 6:46p 🔵 AsyncKit Connection Pool Assertion Still Fires After Five-Site Fix
1911 " 🔵 MemoGeneratorTests, HermesMemoryServiceTests, AchievementsServiceTests Do Not Use HTTP App Testing
1912 6:47p 🔵 Production App Conditionally Registers Fluent with ServiceGroup
1913 " 🔵 Test Suite Exits with Signal 5 Due to Remaining AsyncKit Assertions
1914 6:48p 🔵 Working Tree Clean Before Commit — Changes May Already Be Staged or Committed
1915 6:49p ✅ withTestFluent Migration Already Committed to main as "fix build"
1916 " 🔴 SwiftFormat Lint Failures from Deleted `openFluent()` Helper Cleanup
1917 6:50p 🔴 SwiftFormat Lint Now Passing — 0/198 Files Require Formatting
1918 " 🔵 2 AsyncKit Assertions Persist After Full `withTestFluent` Migration and Lint Fix
1919 6:51p 🔵 Production App Entry Point Uses `runService()` for Full Lifecycle Management
1925 6:55p 🔵 HummingbirdTesting Source Files Located in LuminaVaultServer
1926 " 🔵 HummingbirdTesting RouterTestFramework Lifecycle Pattern
1927 6:56p 🔵 HummingbirdTesting run() Full Body — processesRunBeforeServerStart and Client.executeRequest Details
1929 " 🔵 Direct DB Connection Pool Usage Confined to Three Test Files
1930 " 🔵 ConnectionPool References in AuthFlow and TenantIsolation Tests Are Comments Only
1931 " 🔵 TenantIsolationTests Fluent Setup Pattern — withFluent + makeFluent + Full Migration Stack
1932 " 🔵 LuminaVaultServer Test Suite Creates Fluent Instances Directly Per Test File
1933 6:57p 🔵 AccountDeletionTests Uses defer+Task Shutdown and openTestFluent Without migrate()
1934 " 🔵 AccountDeletionTests Hybrid Pattern: HTTP Router Test + Ephemeral Fluent for DB Verification
1935 " 🔄 AccountDeletionTests Migrated from inline openTestFluent+defer to withTestFluent Helper
1936 6:58p 🔄 AccountDeletionTests openTestFluent() Deleted — Full Migration to withTestFluent Complete
1937 " ✅ Build Passes After AccountDeletionTests withTestFluent Migration
1938 " 🔵 Test Suite Exits with Signal Code 5 (SIGTRAP) Despite 127 Passes — Likely AsyncKit ConnectionPool Deinit Crash
1939 6:59p 🔵 buildApplication Uses Two Reader Variants: noDBTestReader and dbTestReader
1940 " 🔵 HummingbirdFluent Fluent.run() Internally Calls gracefulShutdown — shutdown() Is the Manual Path
1941 " 🔵 Fluent.run() Full Source — Calls shutdown() After gracefulShutdown, shutdown() Delegates to databases.shutdownAsync()
1944 " 🔵 Databases.shutdown() Is @available(*, noasync) — Only shutdownAsync() Is Safe in Test Contexts
1946 7:00p 🔵 AccountDeletionTests withTestFluent Migration Did Not Persist — Old Pattern Still Present
1949 " 🔵 All AccountDeletionTests Edit Operations Were No-Ops — git status Confirms Zero Modified Files
S191 HER-190 Synth-27 contradiction detector skill/prompt/e2e fixture test scaffolding + verify AnyAPI library for iOS client (May 11 at 7:01 PM)
**Investigated**: - HummingbirdTesting source: RouterTestFramework.swift and TestApplication.swift located at .build/checkouts/hummingbird/Sources/HummingbirdTesting/
    - RouterTestFramework.run() full lifecycle: processesRunBeforeServerStart hooks, ServiceGroup integration, graceful shutdown after test
    - HummingbirdFluent Fluent.run() and shutdown() chain: run() → gracefulShutdown() + shutdown() → databases.shutdownAsync() → pool.shutdownAsync()
    - Databases.shutdown() is @available(*, noasync) — only shutdownAsync() is safe in async test contexts
    - All 14 test files with inline Fluent(logger:) construction identified across Memory, Auth, Skills, Achievements, Health, Admin, APNS, Account, Tenancy domains
    - ConnectionPool grep hits in AuthFlowTests and TenantIsolationTests are comments only, not actual usage
    - AccountDeletionTests full structure: hybrid app.test(.router) + ephemeral Fluent for DB verification pattern
    - TenantIsolationTests full structure: withFluent wrapper, makeFluent() with M00–M15 migrations, TestPostgres.configuration()
    - buildApplication() takes noDBTestReader (no DB tests) or dbTestReader (DB-backed tests)
    - git status confirms zero tracked file modifications in the entire session

**Learned**: - withTestFluent(label:) free function is the intended canonical test helper for ephemeral Fluent lifecycle — but it does NOT yet exist in FluentTestSupport.swift
    - The defer { Task { try? await fluent.shutdown() } } pattern is unsafe (fire-and-forget) and causes AsyncKit ConnectionPool deinit SIGTRAP (signal code 5) on test teardown
    - Test suite currently exits with signal 5 + 2 assertion failures despite 127 tests passing — the ConnectionPool crash is an active bug
    - Edit operations on AccountDeletionTests reported success with structured patches but wrote nothing to disk (confirmed by git status showing zero modified files)
    - The premature edits referenced withTestFluent which doesn't exist yet — likely caused silent no-op matching failures
    - RouterTestFramework.Client sends requests in-process (no TCP), making HB tests fast and deterministic
    - processesRunBeforeServerStart hooks run after ServiceGroup is live — correct place for DB seeding in e2e tests
    - Current migration stack ends at M15_AddTierFields() — new tests must include all M00–M15
    - TestPostgres.configuration() is the single source of truth for test DB connection config

**Completed**: - Deep investigation of HummingbirdTesting, HummingbirdFluent, and FluentKit shutdown chains
    - Full mapping of existing test patterns (TenantIsolationTests withFluent, AccountDeletionTests hybrid HTTP+DB, SkillRunCapGuardTests as skill-domain precedent)
    - Confirmed withTestFluent does not yet exist — must be created in FluentTestSupport.swift before AccountDeletionTests migration
    - Confirmed SIGTRAP root cause: Fluent instances created without guaranteed shutdown across 14 test files
    - No files modified on disk (all edit attempts were no-ops)

**Next Steps**: - Define withTestFluent(label:) free function in Tests/AppTests/Support/FluentTestSupport.swift
    - Migrate AccountDeletionTests.swift to use withTestFluent (replacing openTestFluent + defer+Task at lines 196 and 234)
    - Run swift test to confirm SIGTRAP / signal 5 is resolved
    - Scaffold HER-190 contradiction-detector skill/prompt/e2e fixture test (new test file in Tests/AppTests/Skills/)
    - Investigate AnyAPI (github.com/jpmcglone/AnyAPI) for iOS client suitability and add dependency if appropriate


Access 167k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>