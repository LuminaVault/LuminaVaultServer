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

# [LuminaVaultServer] recent context, 2026-06-05 9:43pm GMT+1

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (17,579t read) | 146,336t work | 88% savings

### Jun 4, 2026
12568 6:07p 🟣 RELEASE-RUNBOOK.md Created: Complete TestFlight → App Store Ordered Runbook
12569 6:08p ✅ RELEASE-RUNBOOK.md Committed to LuminaVaultClient Repository
12570 6:10p 🟣 Support Page Created at web/support.html for App Store Support URL Requirement
12571 " 🔵 prod.yml Env Var Injection Pattern: GH Secrets Upserted into .env.production on VPS
12572 " 🟣 ADMIN_TOKEN Wired into prod.yml Deploy Pipeline
12573 6:11p 🟣 ADMIN_TOKEN Secret Generated and Set on LuminaVaultServer GitHub Repo
12574 " 🟣 Support Page + ADMIN_TOKEN Deploy Committed, Pushed, and Deploy Triggered
12576 6:27p 🔵 LuminaVaultServer Production Deployment Verified — Admin Endpoint Disabled
12577 6:28p 🔴 ADMIN_TOKEN Not Written to .env.production Due to printenv Shell Variable Visibility Bug
12578 " ✅ ADMIN_TOKEN Fix Committed and Deployed to Production
S944 Production readiness checklist — identifying and completing remaining steps to get LuminaVault app to production (Jun 4 at 6:29 PM)
12582 6:44p 🔵 LuminaVaultServer Production Endpoints Verified Live
S946 Fix missing production steps for LuminaVaultClient iOS app TestFlight upload — resolve App Store Connect validation errors blocking submission (Jun 4 at 6:44 PM)
12616 7:07p 🔵 App Store Connect Submission Blocked by Four Validation Errors
12618 7:08p 🔵 Beta xcconfig Missing Real Google Client ID — Root Cause of URL Scheme Error
12619 " 🔵 AppIcon Asset Catalog Contains Only 1024px JPG — All Required PNG Sizes Missing
12620 " 🔵 Config.Beta.xcconfig Exists but Retains Placeholder Google Client ID
12623 7:09p 🔵 Source App Icon is 784×1168 JPEG — Wrong Dimensions and Wrong Format
12626 7:10p 🔴 App Icon Converted to Valid 1024×1024 Square PNG
12627 " 🔴 Contents.json Updated to Wire icon_1024.png to Asset Catalog Entry
12629 7:11p 🔴 Old JPEG Icon Removed from Asset Catalog via git rm
12630 " 🔵 Config.Beta.xcconfig Has Three Unfilled Placeholders Beyond Google Client ID
12631 7:12p 🔴 Config.Beta.xcconfig: Google Client ID Placeholders Replaced and API Domain Corrected
12632 " ✅ Beta Config Legal URLs Updated from luminavault.com to luminavault.fyi
12641 7:17p 🔵 LuminaVaultClient iOS Build Failing with Disk I/O Error on Build Database
12642 7:19p 🔵 LuminaVaultClient Build Blocked by Swift Package Manager Dependency Resolution Failure
12643 7:20p 🔴 Fixed App Icon (JPEG→PNG) and Beta Google OAuth URL Scheme Placeholder
12644 " ✅ App Icon Fix Pushed to LuminaVaultClient main Branch
S947 Fix missing production steps for LuminaVaultClient iOS TestFlight upload — resolve App Store Connect validation errors and update release documentation (Jun 4 at 7:21 PM)
12645 7:23p 🔵 Admin Tier Override API Exists but ADMIN_TOKEN is Unset — Endpoint Disabled
12646 " ✅ Runbook Updated: ADMIN_TOKEN Confirmed Live on Server, Retrieval Command Added
12647 7:24p 🔵 RELEASE-RUNBOOK.md Section D Still Contains Stale ADMIN_TOKEN Instructions
12648 " ✅ RELEASE-RUNBOOK.md Section D Updated and New Section E Added for Command Context
12649 " ✅ Runbook Updates Committed and Pushed to LuminaVaultClient main
S948 Fix fastlane match encryption crash ("couldn't set additional authenticated data") when running ios beta lane for LuminaVaultClient (Jun 4 at 7:25 PM)
12650 7:25p 🔵 Matchfile git_url Points to Main LuminaVaultClient Repo — Not a Separate Private Certs Repo
12651 7:29p 🔵 Fastlane Match OpenSSL Encryption Failure on iOS Beta Lane
12652 7:30p 🔵 LuminaVaultClient Matchfile Uses Git Storage with Development Type Default
12653 " ✅ Matchfile Migrated to Dedicated Private Certs Repo with Appstore Type
12654 7:31p 🔵 Root Cause: LibreSSL 3.3.6 Incompatible with Fastlane Match AES-GCM Encryption
12655 " ✅ Canonical Matchfile Created in fastlane/ Directory
S949 Fix fastlane match encryption crash for LuminaVaultClient ios beta lane — identified LibreSSL root cause, corrected Matchfile repo URLs to LuminaVaultIOSSecrets (Jun 4 at 7:32 PM)
12656 7:33p ✅ Matchfile Certs Repo Renamed to LuminaVaultIOSSecrets
12657 7:34p ✅ Legacy Matchfile Synced to LuminaVaultIOSSecrets Repo URL
S950 Fix Ruby/Bundler compatibility issues in LuminaVaultClient to enable bundle install and fastlane runs (Jun 4 at 7:34 PM)
12669 7:39p 🔵 Bundler 1.17.2 Incompatible with Ruby 4.0 in LuminaVaultClient
12671 " 🔵 LuminaVaultClient Gemfile.lock Pinned to Bundler 1.17.2 with fastlane 2.230.0
12672 " 🔴 Updated LuminaVaultClient Gemfile.lock BUNDLED WITH to 4.0.13
S956 Audit and configure Apple APNS + Apple Sign-In (SiwA) environment variables for LuminaVaultServer production and GitHub (Jun 4 at 7:40 PM)
12682 8:07p 🚨 Apple APNS and OAuth Private Keys Exposed in Plain Text
12683 " 🔵 APNS and Apple OAuth Secrets Completely Missing from GitHub and prod.yml
12684 8:08p 🔵 Apple Sign-In Client ID Mismatch: Client Uses com.lumina.fernando, Server Config Uses facorreia.financeplan.signin
12685 8:09p 🔵 docker-compose.production.yml Maps OAUTH_APPLE_CLIENT_ID from OAUTH_APPLE_CLIENTID (no underscore before ID)
12686 " ✅ docker-compose.production.yml: OAuth Defaults Hardcoded and APNS Key Path Confirmed
12687 8:10p 🟣 Apple + Google OAuth Client ID Defaults Deployed to Production
S957 Understanding how to obtain APNS and OAUTH_APPLE credentials for a backend server supporting the Lumina app (com.lumina.fernando) (Jun 4 at 8:11 PM)
12688 8:16p 🔵 Apple APNS and Sign-in-with-Apple OAuth Credential Requirements
S958 Clarifying where the APNS_KEYID value comes from and how it relates to the .p8 key file (Jun 4 at 8:16 PM)
S959 Production readiness checklist for LuminaVaultServer — identifying missing steps to reach prod (Jun 4 at 8:25 PM)
### Jun 5, 2026
12876 5:22p 🔵 APNS Setup Research for TestFlight and Production

Access 146k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>