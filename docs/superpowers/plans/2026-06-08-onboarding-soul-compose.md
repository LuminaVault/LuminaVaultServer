# Onboarding-Seeded SOUL.md Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `POST /v1/soul/compose` endpoint that renders structured onboarding inputs (agent name, tone, role, autonomy) into a filled SOUL.md, replacing the TODO-placeholder default template.

**Architecture:** New `SoulComposeRequest` DTO in LuminaVaultShared (v0.78.0). Server-side `SOULComposer` deterministically renders the markdown; `SoulController.compose()` writes it via the existing `SOULService` (vault file + `data/hermes/SOUL.md` mirror) and returns the rendered body. Phase-2 LLM synthesis slots into `SOULComposer.render` with no endpoint/DTO change.

**Tech Stack:** Swift 6, Hummingbird, LuminaVaultShared (cross-repo wire DTOs), swift-testing/XCTest, openapi.yaml + Bruno.

**Spec:** `docs/superpowers/specs/2026-06-08-onboarding-soul-compose-design.md`

**Cross-repo note:** LuminaVaultShared is a sibling repo at `~/Projects/ObsidianClaudeBrain/LuminaVaultShared`, consumed by the server via a git tag pin in `Package.swift` (`from: "0.77.0"`). The shared change (Task 1) must be committed, tagged `v0.78.0`, and pushed BEFORE the server repin (Task 5) resolves. Per the `graph_memory_centric_and_shared_pin` incident: verify the pin after any `Package.swift` edit.

**Build verification rule:** Always verify with `swift build; echo EXIT=$?` then grep for `error:` — never pipe build output to `tail` (it masks the real exit code; see `feedback_verify_build_exit_code`).

---

## File Structure

**LuminaVaultShared:**
- Modify: `Sources/LuminaVaultShared/APIDTOs.swift` — add `SoulComposeRequest` + `SoulTone`/`SoulRole`/`SoulAutonomy` enums in the `// ─── SOUL ───` section (after line 228).
- Test: `Tests/LuminaVaultSharedTests/SoulComposeRequestTests.swift` (new) — decode round-trip + snake_case wire mapping.

**LuminaVaultServer:**
- Create: `Sources/App/Auth/SOULComposer.swift` — pure render function, sibling to `SOULDefaultTemplate.swift`.
- Modify: `Sources/App/Auth/SoulController.swift` — add `compose` route + handler.
- Modify: `Sources/AppAPI/openapi.yaml` — `POST /v1/soul/compose` + schemas.
- Modify: `Package.swift:24` — repin LuminaVaultShared `from: "0.78.0"`.
- Test: `Tests/AppTests/SOULComposerTests.swift` (new), `Tests/AppTests/SoulControllerComposeTests.swift` (new).

---

## Task 1: Shared DTO — `SoulComposeRequest` + enums

**Files:**
- Modify: `~/Projects/ObsidianClaudeBrain/LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift` (after line 228, end of SOUL section)
- Test: `~/Projects/ObsidianClaudeBrain/LuminaVaultShared/Tests/LuminaVaultSharedTests/SoulComposeRequestTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/LuminaVaultSharedTests/SoulComposeRequestTests.swift`:

```swift
import XCTest
@testable import LuminaVaultShared

final class SoulComposeRequestTests: XCTestCase {
    func testDecodesFromSnakeCaseWire() throws {
        let json = """
        { "agent_name": "Athena", "tone": "warm", "role": "second_brain", "autonomy": "ask_first" }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(SoulComposeRequest.self, from: json)
        XCTAssertEqual(req.agentName, "Athena")
        XCTAssertEqual(req.tone, .warm)
        XCTAssertEqual(req.role, .secondBrain)
        XCTAssertEqual(req.autonomy, .askFirst)
    }

    func testEncodeRoundTrip() throws {
        let req = SoulComposeRequest(agentName: "Hermes", tone: .conciseTechnical, role: .coworker, autonomy: .act)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(SoulComposeRequest.self, from: data)
        XCTAssertEqual(back.tone, .conciseTechnical)
        XCTAssertEqual(back.role, .coworker)
        XCTAssertEqual(back.autonomy, .act)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultShared && swift test --filter SoulComposeRequestTests 2>&1 | grep -E "error:|cannot find" ; echo EXIT=${PIPESTATUS[0]}`
Expected: FAIL — `cannot find 'SoulComposeRequest' in scope`.

- [ ] **Step 3: Write the DTO + enums**

In `APIDTOs.swift`, immediately after `SoulPutRequest` (line 228), before the `// ─── LLM / Chat ───` divider:

```swift
public enum SoulTone: String, Codable, Sendable {
    case warm
    case conciseTechnical = "concise_technical"
    case playful
    case coach
}

public enum SoulRole: String, Codable, Sendable {
    case assistant
    case coworker
    case coach
    case secondBrain = "second_brain"
}

public enum SoulAutonomy: String, Codable, Sendable {
    case askFirst = "ask_first"
    case suggest
    case act
}

/// HER-100 — structured onboarding inputs the server renders into a filled
/// SOUL.md via `POST /v1/soul/compose`. Replaces the TODO-placeholder default.
public struct SoulComposeRequest: Codable, Sendable {
    public let agentName: String
    public let tone: SoulTone
    public let role: SoulRole
    public let autonomy: SoulAutonomy

    enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case tone, role, autonomy
    }

    public init(agentName: String, tone: SoulTone, role: SoulRole, autonomy: SoulAutonomy) {
        self.agentName = agentName
        self.tone = tone
        self.role = role
        self.autonomy = autonomy
    }
}
```

> Note: `role` enum has BOTH a `.coach` case and `SoulTone` has a `.coach` case — they are distinct types, no clash. The `coach` raw value is intentionally shared across the two enums.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultShared && swift test --filter SoulComposeRequestTests 2>&1 | tail -5 ; swift build; echo EXIT=$?`
Expected: tests PASS, `EXIT=0`.

- [ ] **Step 5: Commit, bump version, tag, push**

The version lives in the git tag (SPM resolves `from:` against tags). Confirm there is no hardcoded version string to bump first:

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultShared && grep -rn "0.77.0" . --include=*.swift --include=*.md 2>/dev/null | grep -iv test`

If a version constant exists (e.g. in a `Version.swift` or README badge), update it to `0.78.0` in the same commit.

```bash
cd ~/Projects/ObsidianClaudeBrain/LuminaVaultShared
git add Sources/LuminaVaultShared/APIDTOs.swift Tests/LuminaVaultSharedTests/SoulComposeRequestTests.swift
git commit -m "feat: SoulComposeRequest DTO for onboarding SOUL compose

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git tag v0.78.0
git push origin main
git push origin v0.78.0
```

---

## Task 2: Server — `SOULComposer.render`

**Files:**
- Create: `Sources/App/Auth/SOULComposer.swift`
- Test: `Tests/AppTests/SOULComposerTests.swift`

> Depends on Task 5 repin to compile against the new DTO. To work TDD before the repin resolves, temporarily add the local shared package via `.package(path:)` override OR run Task 5 first, then return here. **Recommended ordering: do Task 1 → Task 5 (repin) → Task 2.** Tasks are written in dependency order below; if executing strictly top-to-bottom, jump to Task 5 after Task 1, then resume Task 2.

- [ ] **Step 1: Write the failing test**

Create `Tests/AppTests/SOULComposerTests.swift`:

```swift
import XCTest
import LuminaVaultShared
@testable import App

final class SOULComposerTests: XCTestCase {
    private func render(_ tone: SoulTone = .warm,
                        _ role: SoulRole = .secondBrain,
                        _ autonomy: SoulAutonomy = .suggest,
                        name: String = "Athena") -> String {
        let req = SoulComposeRequest(agentName: name, tone: tone, role: role, autonomy: autonomy)
        return SOULComposer.render(req, username: "fernando")
    }

    func testFrontmatterPresent() {
        let out = render()
        XCTAssertTrue(out.hasPrefix("---\n"), "must start with frontmatter")
        XCTAssertTrue(out.contains("username: fernando"))
        XCTAssertTrue(out.contains("version: \(SOULComposer.version)"))
    }

    func testAgentNameInIdentity() {
        XCTAssertTrue(render(name: "Athena").contains("Athena"))
    }

    func testEmptyNameDefaultsToHermes() {
        XCTAssertTrue(render(name: "").contains("Hermes"))
    }

    func testToneRendersDistinctVoice() {
        XCTAssertTrue(render(.conciseTechnical).lowercased().contains("concise"))
        XCTAssertTrue(render(.playful).lowercased().contains("playful"))
    }

    func testAutonomyRendersOperations() {
        XCTAssertTrue(render(.warm, .secondBrain, .act).lowercased().contains("act"))
        XCTAssertTrue(render(.warm, .secondBrain, .askFirst).lowercased().contains("confirm"))
    }

    func testNoPlaceholderCommentsRemain() {
        XCTAssertFalse(render().contains("<!--"), "composed SOUL must be filled, not templated")
    }

    func testUnderSizeCap() {
        XCTAssertLessThan(render().utf8.count, 64 * 1024)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift test --filter SOULComposerTests 2>&1 | grep -E "error:|cannot find" ; echo done`
Expected: FAIL — `cannot find 'SOULComposer' in scope`.

- [ ] **Step 3: Write `SOULComposer.swift`**

Create `Sources/App/Auth/SOULComposer.swift`:

```swift
import Foundation
import LuminaVaultShared

/// HER-100: renders structured onboarding inputs into a filled `SOUL.md`.
/// Deterministic by design — SOUL is prompt-injection-scanned on every load,
/// so the body must be predictable. Phase-2 LLM synthesis replaces the body
/// here without changing `SoulController` or `SoulComposeRequest`.
enum SOULComposer {
    static let version = 1

    static func render(_ req: SoulComposeRequest, username: String, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter().string(from: now)
        let name = req.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Hermes" : req.agentName

        let voice: String
        switch req.tone {
        case .warm: voice = "Warm, encouraging, and plain-spoken. Lead with empathy, stay direct."
        case .conciseTechnical: voice = "A concise technical expert. No fluff — facts, code, and clear next steps."
        case .playful: voice = "Playful and light, with occasional wit. Never at the expense of clarity."
        case .coach: voice = "A direct coach. Challenge assumptions and push toward action."
        }

        let identity: String
        switch req.role {
        case .assistant: identity = "your assistant — you ask, I do, and I keep things moving."
        case .coworker: identity = "your coworker — a peer who happens to know your whole context."
        case .coach: identity = "your coach — I track your goals and hold you to them."
        case .secondBrain: identity = "your second brain — I remember everything so you don't have to."
        }

        let operations: String
        switch req.autonomy {
        case .askFirst: operations = "Confirm before any non-trivial action. When in doubt, ask."
        case .suggest: operations = "Propose actions and wait for a clear go-ahead before acting."
        case .act: operations = "Act on clear intent, then report what was done. Don't stall on confirmations."
        }

        return """
        ---
        version: \(version)
        username: \(username)
        created_at: \(iso)
        ---

        # SOUL.md

        ## Identity

        I am \(name), \(identity) I read this file on every reply, so it defines who I am for \(username).

        ## Values

        - \(username)'s time and attention are the scarcest resource — protect them.
        - Privacy first: nothing about \(username) leaves their control.
        - Truth over comfort: surface what's real, even when it's inconvenient.

        ## Voice

        \(voice)

        ## Operations

        \(operations) Keep continuity across sessions by leaning on memory rather than re-asking.

        ## Restrictions

        - Never invent facts about \(username); if unknown, say so.
        - Never surface anything \(username) has marked private or asked me to drop.
        - No destructive action without explicit confirmation.

        ## Failure protocol

        When a tool, memory, or model call fails: say so plainly, state what I could and couldn't do, and offer the next concrete step. Never paper over an error with a confident guess.
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift test --filter SOULComposerTests 2>&1 | tail -8`
Expected: all SOULComposerTests PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer
git add Sources/App/Auth/SOULComposer.swift Tests/AppTests/SOULComposerTests.swift
git commit -m "feat: SOULComposer renders onboarding inputs into filled SOUL.md

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Server — `SoulController.compose` handler + route

**Files:**
- Modify: `Sources/App/Auth/SoulController.swift` (add route at line ~18, handler after `put`)
- Test: `Tests/AppTests/SoulControllerComposeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AppTests/SoulControllerComposeTests.swift`. Match the existing AppTests harness for an authenticated request (copy the setup pattern from the nearest existing controller test, e.g. an existing `SoulController` or auth test — find it with `grep -rl "SoulController\|requireIdentity" Tests/AppTests`):

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
@testable import App

final class SoulControllerComposeTests: XCTestCase {
    func testComposeWritesFilledSoulAndReturnsMarkdown() async throws {
        try await withApp { app, token in   // withApp = shared test harness; see existing AppTests helpers
            let body = SoulComposeRequest(agentName: "Athena", tone: .warm, role: .secondBrain, autonomy: .suggest)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/v1/soul/compose",
                    method: .post,
                    auth: .bearer(token),
                    body: JSONEncoder().encodeAsByteBuffer(body, allocator: .init())
                ) { res in
                    XCTAssertEqual(res.status, .ok)
                    let decoded = try JSONDecoder().decode(SoulResponse.self, from: res.body)
                    XCTAssertTrue(decoded.markdown.contains("Athena"))
                    XCTAssertFalse(decoded.markdown.contains("<!--"))
                }
            }
        }
    }
}
```

> If the existing AppTests harness uses a different bootstrap (no `withApp`/`token` helper), adapt this test to that harness — the assertions (status 200, markdown contains agent name, no `<!--`) are what matter. Inspect a sibling test first.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift test --filter SoulControllerComposeTests 2>&1 | grep -E "error:|404|not found|cannot find" ; echo done`
Expected: FAIL — route not registered (404) or compile error (no `compose`).

- [ ] **Step 3: Add the route + handler**

In `Sources/App/Auth/SoulController.swift`, add the route inside `addRoutes`:

```swift
    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: get)
        router.put("", use: put)
        router.post("compose", use: compose)
        router.delete("", use: delete)
    }
```

Add the handler after `put` (mirrors `put`'s error + achievement handling):

```swift
    @Sendable
    func compose(_ req: Request, ctx: AppRequestContext) async throws -> SoulResponse {
        let user = try ctx.requireIdentity()
        let composeRequest = try await req.decode(as: SoulComposeRequest.self, context: ctx)
        let body = SOULComposer.render(composeRequest, username: user.username)
        return try await telemetry.observe("soul.compose") {
            do {
                try service.write(for: user, body: body)
            } catch let SOULServiceError.tooLarge(bytes, limit) {
                throw HTTPError(.contentTooLarge, message: "SOUL.md too large: \(bytes) bytes > \(limit)")
            }
            if let achievements {
                let tenantID = try user.requireID()
                achievements.enqueue(tenantID: tenantID, event: .soulConfigured)
            }
            return SoulResponse(markdown: body, updatedAt: service.updatedAt(for: user))
        }
    }
```

> Verify `user.username` is the correct property name — confirm with `grep -n "var username\|let username" Sources/App/Models/User*.swift`. `SOULDefaultTemplate` is already called with a username elsewhere, so the property exists; match its accessor.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift test --filter SoulControllerComposeTests 2>&1 | tail -10 ; swift build; echo EXIT=$?`
Expected: test PASS, `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer
git add Sources/App/Auth/SoulController.swift Tests/AppTests/SoulControllerComposeTests.swift
git commit -m "feat: POST /v1/soul/compose endpoint

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: openapi.yaml + Bruno regen

**Files:**
- Modify: `Sources/AppAPI/openapi.yaml`

- [ ] **Step 1: Locate the existing SOUL paths + schemas**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && grep -n "/v1/soul\|SoulPutRequest\|SoulResponse" Sources/AppAPI/openapi.yaml`
Note the indentation/style of the existing `/v1/soul` path and `SoulPutRequest` schema to match.

- [ ] **Step 2: Add the path**

Under `paths:`, add (matching existing 2-space style, JWT security like the other soul routes):

```yaml
  /v1/soul/compose:
    post:
      operationId: composeSoul
      summary: Render structured onboarding inputs into a filled SOUL.md
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/SoulComposeRequest'
      responses:
        '200':
          description: Rendered and persisted SOUL.md
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/SoulResponse'
        '413':
          description: Rendered SOUL exceeds the 64 KiB cap
```

- [ ] **Step 3: Add the schema**

Under `components.schemas:`, after `SoulPutRequest`:

```yaml
    SoulComposeRequest:
      type: object
      required: [agent_name, tone, role, autonomy]
      properties:
        agent_name:
          type: string
          example: Athena
        tone:
          type: string
          enum: [warm, concise_technical, playful, coach]
        role:
          type: string
          enum: [assistant, coworker, coach, second_brain]
        autonomy:
          type: string
          enum: [ask_first, suggest, act]
```

- [ ] **Step 4: Regenerate Bruno collection**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && make bruno-regen 2>&1 | tail -15`
Expected: regen succeeds (the `bru CLI v3` temp-dir workaround is already wired into the make target per `project_bru_cli_v3_broken`). Confirm a `compose` request appears under the soul folder.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer
git add Sources/AppAPI/openapi.yaml bruno/
git commit -m "docs: openapi + bruno for POST /v1/soul/compose

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Repin LuminaVaultShared to 0.78.0

> **Run this immediately after Task 1** (tag pushed) so Tasks 2–3 compile against the new DTO.

**Files:**
- Modify: `Package.swift:24`

- [ ] **Step 1: Edit the pin**

Change line 24 from:
```swift
        .package(url: "https://github.com/LuminaVault/LuminaVaultShared.git", from: "0.77.0"),
```
to:
```swift
        .package(url: "https://github.com/LuminaVault/LuminaVaultShared.git", from: "0.78.0"),
```

- [ ] **Step 2: Resolve + verify the pin landed**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift package update LuminaVaultShared 2>&1 | tail -5 && grep -A3 "LuminaVaultShared" Package.resolved | grep version`
Expected: `Package.resolved` shows `"version": "0.78.0"`. (Per the shared-pin landmine: if `swift package edit` was ever used on this dep, run `swift package unedit LuminaVaultShared` first.)

- [ ] **Step 3: Verify build resolves the new DTO**

Run: `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift build 2>&1 | grep -E "error:" ; echo EXIT=$?`
Expected: no `error:` lines, `EXIT=0`.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer
git add Package.swift Package.resolved
git commit -m "chore: repin LuminaVaultShared 0.78.0 (SoulComposeRequest)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Full build green:** `cd ~/Projects/ObsidianClaudeBrain/LuminaVaultServer && swift build; echo EXIT=$?` → `EXIT=0`
- [ ] **Targeted tests green:** `swift test --filter SOULComposer 2>&1 | tail -5` and `swift test --filter SoulControllerCompose 2>&1 | tail -5` (repo-wide `swift test` has the HER-310 SIGILL flake — run filtered).
- [ ] **Manual smoke (optional, against local server):** `POST /v1/soul/compose` with a sample body, then `GET /v1/soul` returns the filled markdown; confirm `data/hermes/SOUL.md` mirror updated and contains no `<!--`.
- [ ] **Client follow-up (separate repo, out of scope here):** iOS onboarding posts `SoulComposeRequest` then PATCHes `soulConfiguredCompleted=true`.

## Execution Order Summary

Task 1 → Task 5 (repin) → Task 2 → Task 3 → Task 4. (Task 5 is placed after the others in the doc for readability but must run right after Task 1 so the server compiles against the new DTO.)
