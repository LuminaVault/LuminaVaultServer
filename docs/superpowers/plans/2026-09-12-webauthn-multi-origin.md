# WebAuthn Multi-Origin Implementation Plan

> **Two repos.** Tasks 1-3 are `LuminaVaultServer`. Task 4 is
> `LuminaVaultWebApp` and unrelated to WebAuthn — branch and PR it separately.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one LuminaVault deployment accept WebAuthn ceremonies from more than one origin, so web (`https://app.luminavault.fyi`) and iOS native (`https://luminavault.fyi`) can both use passkeys under the relying-party ID `luminavault.fyi`.

**Architecture:** `WebAuthnService` holds a single `relyingPartyOrigin: String` and builds one `WebAuthnManager` from it. The swift-webauthn library takes exactly one origin in its `Configuration` and verifies against it internally, so multi-origin cannot be expressed as a config value. Instead the service parses a comma-separated origin list into an ordered `[String]`, and the two `finish*` ceremonies attempt verification against each configured origin, succeeding on the first that verifies and rethrowing the last error if none do. Every attempt is a complete cryptographic verification by the library — this asks "is this credential valid for *any* origin we accept", the same intersection semantics server PR #197 used for OAuth audiences.

**Tech Stack:** Swift 6, Hummingbird, swift-webauthn, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-12-web-auth-parity-design.md`

## Global Constraints

- Swift 6 language mode, strict concurrency. No `@unchecked Sendable` or `nonisolated(unsafe)` without a documented reason in a comment.
- New types default to `struct` + `Sendable`.
- Server tests **cannot build on the dev machine** — the Command Line Tools SDK has no XCTest, so `swift build --build-tests` fails with `clang dependency scanning failure`. Verify with `swift build --target App` locally; **CI is the verdict on tests**.
- `swiftformat --lint .` must report `0/N files require formatting` before commit. CI runs `swiftlint lint` with no `--strict`, so SwiftLint *errors* fail the build (note: `function_parameter_count` errors at 8+ parameters).
- A single configured origin must keep behaving exactly as it does today — every current deployment has one value.
- `openapi.yaml` is the API contract, but this change alters no request or response shape, so no spec edit and no `make bruno-regen` is required.

---

### Task 1: Parse a comma-separated origin list

**Files:**
- Modify: `Sources/App/Auth/WebAuthnService.swift:112-135`
- Test: `Tests/AppTests/Auth/WebAuthnOriginsTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `WebAuthnService.parseOrigins(_ raw: String) -> [String]` (static, internal) and a stored `relyingPartyOrigins: [String]` on `WebAuthnService`. Task 2 consumes both.

- [ ] **Step 1: Write the failing test**

Create `Tests/AppTests/Auth/WebAuthnOriginsTests.swift`:

```swift
@testable import App
import Foundation
import Testing

/// Origin parsing for WebAuthn.
///
/// The relying-party ID `luminavault.fyi` is shared by two origins — the web
/// app at `https://app.luminavault.fyi` and iOS native, which presents
/// `https://luminavault.fyi`. One configured string cannot serve both, so the
/// value became a list. A single value must keep behaving exactly as it does
/// today: that is what every current deployment has.
struct WebAuthnOriginsTests {
    @Test
    func `a single origin parses to one entry`() {
        #expect(WebAuthnService.parseOrigins("https://api.luminavault.fyi") == ["https://api.luminavault.fyi"])
    }

    @Test
    func `a comma separated list parses in order`() {
        #expect(
            WebAuthnService.parseOrigins("https://app.luminavault.fyi,https://luminavault.fyi")
                == ["https://app.luminavault.fyi", "https://luminavault.fyi"]
        )
    }

    /// A trailing comma or a stray space is the kind of thing that reaches a
    /// sealed secret and is never seen again. An empty entry would build a
    /// manager configured with an empty origin, which fails every ceremony
    /// with an error that says nothing about the real cause.
    @Test
    func `blank and whitespace-padded entries are dropped`() {
        #expect(
            WebAuthnService.parseOrigins(" https://a.example , ,https://b.example, ")
                == ["https://a.example", "https://b.example"]
        )
    }

    @Test
    func `an empty configuration parses to no origins`() {
        #expect(WebAuthnService.parseOrigins("") == [])
        #expect(WebAuthnService.parseOrigins("   ") == [])
        #expect(WebAuthnService.parseOrigins(",,") == [])
    }

    /// Duplicates would make the service verify the same origin twice on every
    /// failed ceremony, for nothing.
    @Test
    func `duplicates collapse while preserving first-seen order`() {
        #expect(
            WebAuthnService.parseOrigins("https://b.example,https://a.example,https://b.example")
                == ["https://b.example", "https://a.example"]
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --target App` (tests cannot build locally — see Global Constraints).

Expected locally: the App target still builds, because the test file is not in it. Push the branch and let CI run `Unit Tests`.
Expected on CI: FAIL with `type 'WebAuthnService' has no member 'parseOrigins'`.

If you can run tests in your environment, use:
`swift test --filter WebAuthnOriginsTests`

- [ ] **Step 3: Write the minimal implementation**

In `Sources/App/Auth/WebAuthnService.swift`, replace the stored property
`let relyingPartyOrigin: String` with the list plus the parser. Keep the
property name `relyingPartyOrigins` plural so every call site fails to compile
until it is updated — a silent fallback to the first origin is exactly the bug
this task exists to prevent.

```swift
    let relyingPartyOrigins: [String]
```

Add inside `struct WebAuthnService`:

```swift
    /// Split a configured origin list into ordered, de-duplicated entries.
    ///
    /// Comma-separated so it stays one environment variable, matching how
    /// `parseOAuthAudiences` handles multi-value OAuth audiences (PR #197).
    /// Blanks are dropped rather than preserved: an empty entry builds a
    /// manager with an empty origin, which fails every ceremony with an error
    /// that points nowhere near the trailing comma that caused it.
    static func parseOrigins(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build --target App`
Expected: FAIL — `manager` still references `relyingPartyOrigin`, and `App+build.swift` still passes it. Task 2 fixes both. Do **not** patch them here; the next task's test is what proves that code correct.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Auth/WebAuthnService.swift Tests/AppTests/Auth/WebAuthnOriginsTests.swift
git commit -m "feat(webauthn): parse a comma-separated relying-party origin list

One configured string cannot serve both the web app at
app.luminavault.fyi and iOS native, which presents luminavault.fyi,
under the shared relying-party ID. Same shape as the multi-value OAuth
audiences in #197: comma-separated so it stays one environment
variable, and a single value keeps behaving exactly as it does today.

Blanks are dropped rather than preserved — an empty entry would build a
manager with an empty origin and fail every ceremony with an error that
points nowhere near the trailing comma that caused it."
```

---

### Task 2: Verify against any configured origin

**Files:**
- Modify: `Sources/App/Auth/WebAuthnService.swift:126-135` (the `manager` property), and the two `finish*` handlers at `:218` and the authentication equivalent
- Modify: `Sources/App/App+build.swift:152` and `:489`
- Test: `Tests/AppTests/Auth/WebAuthnOriginsTests.swift` (extend)

**Interfaces:**
- Consumes: `WebAuthnService.parseOrigins(_:)` and `relyingPartyOrigins: [String]` from Task 1.
- Produces: `WebAuthnService.managers` (`[WebAuthnManager]`, internal computed) and `WebAuthnService.isConfigured` (`Bool`). No caller outside this file depends on them.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AppTests/Auth/WebAuthnOriginsTests.swift`:

```swift
/// Manager construction from the parsed origin list.
///
/// swift-webauthn takes exactly one origin per `WebAuthnManager` and verifies
/// against it internally, so "accept several origins" has to become "hold
/// several managers". These tests pin the arithmetic of that mapping; the
/// ceremonies themselves need a real authenticator and are covered by the
/// library's own suite.
struct WebAuthnManagerSetTests {
    static func service(enabled: Bool = true, id: String = "luminavault.fyi", origins: String)
        -> WebAuthnService
    {
        WebAuthnService(
            enabled: enabled,
            relyingPartyID: id,
            relyingPartyName: "LuminaVault",
            relyingPartyOrigins: WebAuthnService.parseOrigins(origins),
            fluent: TestFluentStub.unusedFluent(),
            repo: TestAuthRepositoryStub(),
            authService: TestAuthServiceStub(),
            logger: Logger(label: "test")
        )
    }

    @Test
    func `one manager is built per configured origin`() {
        let service = Self.service(origins: "https://app.luminavault.fyi,https://luminavault.fyi")
        #expect(service.managers.count == 2)
        #expect(service.isConfigured)
    }

    /// The disabled and unconfigured cases must stay distinguishable from the
    /// configured one, because `addRoutes` refuses to mount on `enabled ==
    /// false` and the handlers 503 on an empty manager set.
    @Test
    func `no origins means not configured`() {
        #expect(Self.service(origins: "").isConfigured == false)
        #expect(Self.service(origins: "").managers.isEmpty)
    }

    @Test
    func `a blank relying-party id means not configured`() {
        #expect(Self.service(id: "", origins: "https://app.luminavault.fyi").isConfigured == false)
    }

    @Test
    func `disabled means not configured even with a full origin list`() {
        #expect(Self.service(enabled: false, origins: "https://app.luminavault.fyi").isConfigured == false)
    }
}
```

**Before writing this test, check whether `TestFluentStub`, `TestAuthRepositoryStub` and `TestAuthServiceStub` exist:**

```bash
grep -rn "AuthRepositoryStub\|AuthServiceStub\|struct.*: AuthRepository\b" Tests/AppTests | head
```

If they do not exist, this test needs real doubles. Prefer constructing the
service through whatever helper `Tests/AppTests/Auth/` already uses — check
`ls Tests/AppTests/Auth/` first and copy the established pattern rather than
inventing stubs. If no pattern exists, drop `WebAuthnManagerSetTests` and rely
on Task 1's parser tests plus CI's build: `managers` is a two-line map over an
already-tested list, and a stub hierarchy invented for it would be more code
than it verifies.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --target App`, then push and read CI.
Expected on CI: FAIL with `type 'WebAuthnService' has no member 'managers'`.

- [ ] **Step 3: Write the minimal implementation**

Replace the `manager` computed property in `Sources/App/Auth/WebAuthnService.swift`:

```swift
    /// One manager per accepted origin.
    ///
    /// `WebAuthnManager.Configuration.relyingPartyOrigin` is a single `String`
    /// and the library verifies against it internally (see
    /// `WebAuthnManager.swift` — the configured origin is passed straight into
    /// the ceremony), so accepting several origins means holding several
    /// managers rather than widening a config value.
    var managers: [WebAuthnManager] {
        guard enabled, !relyingPartyID.isEmpty else { return [] }
        return relyingPartyOrigins.map { origin in
            WebAuthnManager(
                configuration: .init(
                    relyingPartyID: relyingPartyID,
                    relyingPartyName: relyingPartyName,
                    relyingPartyOrigin: origin
                )
            )
        }
    }

    /// Whether any ceremony can run at all. Distinct from `enabled`: a
    /// deployment can have the feature on and the origins unset, which is a
    /// misconfiguration rather than a deliberate opt-out.
    var isConfigured: Bool { !managers.isEmpty }

    /// Run a ceremony against each accepted origin, returning the first
    /// success.
    ///
    /// Every attempt is a full cryptographic verification by the library, so
    /// this asks "is this credential valid for *any* origin we accept" — the
    /// same intersection semantics #197 gave OAuth audiences. It is not a
    /// weakening: a credential that verifies under one accepted origin is
    /// genuinely valid for that origin.
    ///
    /// The last error is rethrown so a genuinely bad credential still reports
    /// the library's own reason rather than a generic failure.
    func firstVerifying<T>(
        _ ceremony: (WebAuthnManager) async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        for manager in managers {
            do {
                return try await ceremony(manager)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HTTPError(.serviceUnavailable, message: "webauthn disabled")
    }
```

In `beginRegistration` and `beginAuthentication`, replace
`guard let manager else { ... }` with:

```swift
        guard let manager = managers.first else {
            throw HTTPError(.serviceUnavailable, message: "webauthn disabled")
        }
```

The `begin` ceremonies only mint a challenge and echo the relying-party ID;
they do not touch the origin, so the first manager is as good as any.

In `finishRegistration`, replace `guard let manager else { ... }` with an
`isConfigured` guard and wrap the ceremony:

```swift
        guard isConfigured else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
```

then change `let credential = try await manager.finishRegistration(` to
`let credential = try await firstVerifying { manager in try await manager.finishRegistration(`
and close the extra brace after the existing call's closing paren.

Apply the identical change to `finishAuthentication`.

- [ ] **Step 4: Update the wiring**

`Sources/App/App+build.swift:152` — the services struct field:

```swift
        webAuthnRelyingPartyOrigin: reader.string(forKey: "webauthn.relyingPartyOrigin", default: ""),
```

leave as-is (still one config read), and at `:489` change the service
construction:

```swift
        relyingPartyOrigins: WebAuthnService.parseOrigins(services.webAuthnRelyingPartyOrigin),
```

Keeping the env var name and the services field singular is deliberate: the
variable is already deployed under that name in a sealed secret, and renaming
it would make an existing deployment silently lose its origin.

- [ ] **Step 5: Verify it builds**

Run: `swift build --target App`
Expected: `Build complete!`

Run: `swiftformat --lint .`
Expected: `0/N files require formatting`

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Auth/WebAuthnService.swift Sources/App/App+build.swift Tests/AppTests/Auth/WebAuthnOriginsTests.swift
git commit -m "feat(webauthn): verify a ceremony against any accepted origin

swift-webauthn takes exactly one origin per WebAuthnManager and verifies
against it internally, so accepting several origins means holding
several managers rather than widening a config value.

finishRegistration and finishAuthentication now try each accepted origin
and take the first that verifies. Every attempt is a full cryptographic
verification by the library, so this asks whether the credential is
valid for any origin we accept — the intersection semantics #197 gave
OAuth audiences. The last error is rethrown so a genuinely bad
credential still reports the library's reason.

The env var and the services field stay singular: the variable is
already deployed under that name in a sealed secret, and renaming it
would make an existing deployment silently lose its origin."
```

---

### Task 3: Document the new configuration

**Files:**
- Modify: `.env.example` (the `WEBAUTHN_*` block)
- Modify: `docker-compose.production.yml` (the WebAuthn env block)
- Modify: `docs/CONFIG.md`

**Interfaces:**
- Consumes: the parsing behaviour from Task 1.
- Produces: nothing code-facing.

- [ ] **Step 1: Update `.env.example`**

Replace the `WEBAUTHN_RELYING_PARTY_ORIGIN` line and add a comment above the block:

```
# --- WebAuthn / Passkeys ---
# RELYING_PARTY_ID must equal the caller's origin domain or be a registrable
# parent of it — never a sibling subdomain. With the web app on
# app.luminavault.fyi and iOS presenting luminavault.fyi, the shared parent is
# the only value that serves both.
#
# Credentials are bound to the ID: changing it invalidates every registered
# passkey and forces each user to re-enrol.
WEBAUTHN_ENABLED=false
WEBAUTHN_RELYING_PARTY_ID=localhost
WEBAUTHN_RELYING_PARTY_NAME=LuminaVault
# Comma-separated. Web and iOS native present different origins under one
# relying-party ID, so a single value cannot serve both. One value behaves
# exactly as it always has.
WEBAUTHN_RELYING_PARTY_ORIGIN=http://localhost:8080
```

- [ ] **Step 2: Update `docker-compose.production.yml`**

Leave the variable name and `${WEBAUTHN_RELYINGPARTYORIGIN:-}` indirection
untouched — only add the comment above it:

```yaml
      # Comma-separated list. Web (app.luminavault.fyi) and iOS native
      # (luminavault.fyi) present different origins under one relying-party
      # ID; a single value cannot serve both.
```

- [ ] **Step 3: Update `docs/CONFIG.md`**

Add to the WebAuthn section (or create one if absent, beside the other
per-feature sections):

```markdown
### WebAuthn / Passkeys

`WEBAUTHN_RELYING_PARTY_ID` must equal the browser's origin domain or be a
registrable parent of it. A sibling subdomain is rejected by the browser
before the request is sent, which is why `api.luminavault.fyi` cannot serve a
web app on `app.luminavault.fyi`.

`WEBAUTHN_RELYING_PARTY_ORIGIN` is a comma-separated list. Web and iOS native
present different origins under one relying-party ID, so one value cannot
serve both; a single value keeps behaving exactly as it did.

Passkey credentials are bound to the relying-party ID. Changing it invalidates
every registered credential and forces all users to re-enrol.

**Known ceiling:** WebAuthn challenges are held in an in-memory dictionary in
`WebAuthnService`, so a `begin` on one API replica and a `finish` on another
will not find the challenge. Passkeys work only while the API runs a single
replica. See `docs/superpowers/plans/2026-05-29-p1-redis-stateless-api.md`.
```

- [ ] **Step 4: Verify nothing else references the old shape**

Run:

```bash
grep -rn "relyingPartyOrigin" Sources Tests --include='*.swift'
```

Expected: only `App+build.swift` (the config read and the `parseOrigins` call)
and `WebAuthnService.swift` (the property and the manager construction).

- [ ] **Step 5: Commit**

```bash
git add .env.example docker-compose.production.yml docs/CONFIG.md
git commit -m "docs(webauthn): record the origin list and the relying-party rules

Writes down the two constraints that are invisible from the code: a
relying-party ID must be the caller's origin domain or a registrable
parent — never a sibling subdomain, which is why api.luminavault.fyi
cannot serve a web app on app.luminavault.fyi — and credentials are
bound to that ID, so changing it forces every user to re-enrol.

Also records the in-memory challenge store as a known ceiling: passkeys
work only while the API runs a single replica."
```

---

### Task 4: Replace the Svelte scaffold favicon — **repo: LuminaVaultWebApp**

Unrelated to WebAuthn. Carried here because it is a two-line fix that would
otherwise wait for a plan of its own. **Different repo** — branch, commit and
PR it separately from Tasks 1–3.

**Files:**
- Modify: `src/routes/+layout.svelte:7,23`
- Delete: `src/lib/assets/favicon.svg`
- Test: `src/lib/brand/favicon.test.ts` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

The tab icon is still SvelteKit's scaffold logo — `src/lib/assets/favicon.svg`
literally contains `<title>svelte-logo</title>`, imported at `+layout.svelte:7`
and bound at `:23`. The Lumina mark already ships as `/icons/pwa-192.png`,
referenced by both `static/manifest.webmanifest` and the `apple-touch-icon` in
`src/app.html`, so the fix points the favicon at the asset the rest of the app
already treats as canonical. There is no Lumina brand SVG in the repo; if one
is added later, prefer it (an SVG favicon scales to every density) and keep the
PNG as the fallback.

- [ ] **Step 1: Write the failing test**

Create `src/lib/brand/favicon.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const layout = readFileSync(
	fileURLToPath(new URL('../../routes/+layout.svelte', import.meta.url)),
	'utf8'
);

describe('favicon', () => {
	// The scaffold favicon shipped for months without anyone noticing, because
	// a wrong tab icon looks like a loading state. Assert on the artifact, not
	// on a rendered head: the bug was a stale import, and an import is what
	// this catches.
	it('does not ship the SvelteKit scaffold logo', () => {
		expect(
			existsSync(fileURLToPath(new URL('../assets/favicon.svg', import.meta.url)))
		).toBe(false);
		expect(layout).not.toContain('$lib/assets/favicon.svg');
	});

	it('points the tab icon at the canonical Lumina mark', () => {
		expect(layout).toContain('/icons/pwa-192.png');
	});
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun run test:unit -- favicon` (check `package.json` for the exact script
name; `bunx vitest run src/lib/brand/favicon.test.ts` also works).
Expected: FAIL on both assertions — the file exists and the layout imports it.

- [ ] **Step 3: Make the change**

In `src/routes/+layout.svelte`, delete line 7:

```ts
	import favicon from '$lib/assets/favicon.svg';
```

and change line 23 from `<link rel="icon" href={favicon} />` to:

```svelte
	<link rel="icon" href="/icons/pwa-192.png" />
```

Then delete the asset:

```bash
git rm src/lib/assets/favicon.svg
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bunx vitest run src/lib/brand/favicon.test.ts`
Expected: PASS, 2 tests.

Then confirm nothing else referenced it:

```bash
grep -rn "assets/favicon" src/ && echo "STILL REFERENCED" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 5: Commit**

```bash
git add src/routes/+layout.svelte src/lib/brand/favicon.test.ts
git commit -m "fix(brand): use the Lumina mark as the tab icon

The favicon was still SvelteKit's scaffold logo — the asset literally
contained <title>svelte-logo</title>. Points at /icons/pwa-192.png,
which static/manifest.webmanifest and the apple-touch-icon in app.html
already treat as the canonical mark, and deletes the scaffold asset.

Tested by asserting the scaffold file is gone and the layout no longer
imports it. A wrong tab icon looks like a loading state, which is why
this survived months of use — so the guard is on the artifact rather
than on a rendered head."
```

---

## Self-Review

**Spec coverage.** Tasks 1-3 implement the spec's *"Server — WebAuthn origin
set"* (sequencing step 1) and the `WEBAUTHN_RELYING_PARTY_ORIGIN` half of its
configuration section. Task 4 is outside this spec entirely — a favicon fix in
another repo, carried here so it does not need a plan of its own. Deliberately
**not** covered here, each needing its own plan or a human:

| Spec section | Where it lands |
|---|---|
| OAuth authorize/callback/session routes | Second plan — needs `ValkeyPersistDriver` and JWTKit ES256 read first |
| Token handoff (one-time code) | Second plan |
| Sealed secrets, RP ID change, AASA, Apple domain verification | Infra + human console work |
| Web UI (buttons, callback route, passkey module) | Web plan, after the console registrations exist |

**Placeholder scan.** No TBD/TODO. Task 2 Step 1 carries a genuine conditional
— whether auth test doubles already exist — with an explicit instruction to
check and an explicit fallback, rather than a guess dressed as fact.

**Type consistency.** `parseOrigins(_:) -> [String]` is defined in Task 1 and
consumed in Tasks 2 and 3 under that exact name. `relyingPartyOrigins: [String]`
is introduced in Task 1 and read in Task 2. `managers` and `isConfigured` are
defined and used only within Task 2. The env var stays
`WEBAUTHN_RELYING_PARTY_ORIGIN` (singular) throughout, which Task 2 Step 4 calls
out as deliberate.

**Deliberate failure between tasks.** Task 1 Step 4 expects a *broken build* —
the property rename breaks `manager` and the wiring on purpose, so the compiler
enumerates every call site instead of a silent fallback to the first origin.
Task 1 is therefore not independently shippable; Tasks 1 and 2 land together or
not at all. That is the one place this plan departs from "every task ends green",
and it is worth it: the alternative is an optional origin list that quietly does
nothing.
