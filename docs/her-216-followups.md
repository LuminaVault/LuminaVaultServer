# HER-216 — Server follow-ups

The HER-216 scaffold (commit on `fernandocorreia316/her-216-webauthn-passkey-enrollment-login-ui`) lands the WebAuthn route renames and credential-management endpoints. It is **not** production-ready. The work below must be completed before iOS HER-216 can ship.

## Hard blockers (must do before iOS ships passkeys)

### 1. Tag `LuminaVaultShared` 0.30.0+ with the new DTOs

The HER-216 scaffold added WebAuthn DTOs to `LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift` on this same branch (commit `2546e0d` in `LuminaVaultShared`). Sequence:

1. Merge the `fernandocorreia316/her-216-webauthn-passkey-enrollment-login-ui` branch in `LuminaVaultShared` to `main`.
2. Tag `0.30.0` (or whatever the next semver bump is).
3. In `LuminaVaultServer/Package.swift`, bump `.package(url: ".../LuminaVaultShared.git", from: "0.29.0")` → `"0.30.0"`.
4. In `LuminaVaultServer/Sources/App/Auth/WebAuthnService.swift`, delete the inline `WebAuthnCredentialSummaryDTO` and `WebAuthnCredentialListResponse` block. Add `import LuminaVaultShared` (already present) and add `extension WebAuthnCredentialListResponse: ResponseEncodable {}`.

### 2. Refactor existing WebAuthn DTOs to consume `LuminaVaultShared`

The pre-existing inline types in `WebAuthnService.swift` (`WebAuthnBeginRegistrationRequest`, `WebAuthnFinishRegistrationRequest`, `WebAuthnBeginAuthenticationRequest`, `WebAuthnFinishAuthenticationRequest`, `WebAuthnBeginRegistrationResponse`, `WebAuthnFinishRegistrationResponse`, `WebAuthnBeginAuthenticationResponse`) violate `LuminaVaultServer/CLAUDE.md §3`.

Replacement plan:

* `WebAuthnBeginRegistrationRequest` — direct swap, fields identical.
* `WebAuthnBeginAuthenticationRequest` — direct swap, fields identical.
* `WebAuthnFinishRegistrationRequest` / `WebAuthnFinishAuthenticationRequest` — the shared variants use base64url-string DTOs (`WebAuthnRegistrationCredentialDTO`, `WebAuthnAuthenticationCredentialDTO`). The route handler must reconstruct the swift-webauthn `RegistrationCredential` / `AuthenticationCredential` value. Cleanest path: JSON-encode the shared DTO, JSON-decode as the swift-webauthn type (shape is identical). One-line helper.

Verify with a round-trip test that `JSONEncoder().encode(WebAuthnRegistrationCredentialDTO(…))` decodes cleanly as `RegistrationCredential`.

### 3. Regenerate Bruno collection

After every `openapi.yaml` change, run `make bruno-regen` and commit the resulting `.bru` diffs. Required by `LuminaVaultServer/CLAUDE.md §2`.

### 4. Serve `apple-app-site-association` with the `webcredentials` block

iCloud Keychain sync depends on the RP-ID's apex domain serving an AASA file with a `webcredentials` entry that lists the app's bundle ID. Example:

```json
{
  "applinks": { … existing … },
  "webcredentials": {
    "apps": ["<TEAM_ID>.com.luminavault.client"]
  }
}
```

Verify it's reachable at `https://<rp-id>/.well-known/apple-app-site-association` with `Content-Type: application/json` and **no redirect**.

### 5. Remove `/options` aliases

`WebAuthnService.swift` keeps `/register/options` and `/authenticate/options` as deprecated aliases of the new `/begin` paths. After iOS HER-216 ships to TestFlight and main production traffic moves, delete both alias lines + their `openapi.yaml` entries if any.

## Should-do (before ticket marked truly complete)

### 6. Tests

No `WebAuthnTests.swift` exists in `Tests/AppTests`. Add coverage for:

* `beginRegistration` / `beginAuthentication` anti-enumeration (unknown username does NOT 404).
* `finishRegistration` happy path persists a `WebAuthnCredential` row scoped to the right tenant.
* `finishAuthentication` happy path bumps `signCount` and issues `AuthResponse`.
* `finishAuthentication` rejects credential ID belonging to a different tenant (tenant isolation).
* `GET /v1/auth/webauthn/credentials` returns only the authenticated user's credentials.
* `DELETE /v1/auth/webauthn/credentials/{id}` cannot delete another user's credential.
* `WebAuthnChallengeStore` TTL expiry (5min default).

Use `withTestFluent` per the existing test-suite pattern.

### 7. Multi-replica challenge store

`WebAuthnChallengeStore` is `actor`-local memory. Single-VPS deploys are fine; multi-replica deployments must move challenges into a shared `PersistDriver` (Redis is the natural choice once HER-200's rate-limit storage migration lands).

### 8. Credential nickname + revocation telemetry

`WebAuthnCredential` has no `nickname` column today. Add a `M12_AddWebAuthnNickname` migration so Settings can show "iPhone passkey", "MacBook passkey", etc. Also emit a telemetry event when a credential is revoked.

### 9. Discoverable-credential / username-less authentication

The current `beginAuthentication` requires a `username`. To support `ASAuthorizationController.performAutoFillAssistedRequests` on iOS (QuickType passkey autofill), the server must accept a missing username and return options with an empty `allowCredentials` list. This is required only after iOS adds the autofill path.

### 10. X OAuth field bug (not HER-216 but blocks the same provider list)

`Sources/App/Auth/OAuth/XAPIClient.swift:43` requests `user.fields=…,verified_email`. X's `/2/users/me` does NOT accept a `verified_email` user-fields key; it's likely ignored or 400s on strict modes. Field is `verified` only; email is gated behind the `email` scope, not `verified_email`. Fix to `user.fields=id,name,username,verified` and rely on token scopes for email.
