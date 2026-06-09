# Connectivity & Integration Status

Status of the ways LuminaVault connects across the stack. There are **two
independent hops** — they're easy to conflate, so they're separated here.

```
iPhone ──(Layer B: BackendMode)──> LuminaVault server ──(Layer A: BYO Hermes)──> Hermes gateway
```

- **Layer A — BYO Hermes transport:** how the **LuminaVault server** reaches a
  user's self-hosted **Hermes AI gateway**. App plumbing = URL + token,
  `SecretBox` (AES-GCM, per-tenant), `SSRFGuard`, Save&verify probe. The
  transports are operator-side setup (see [`byo-hermes.md`](byo-hermes.md)); no
  per-transport app code is required — you paste the resulting URL.
- **Layer B — `BackendMode`:** how the **iOS client** chooses **which
  LuminaVault server** to talk to. Defined in
  `LuminaVaultClient/Services/ServerConnection/BackendMode.swift`;
  `Config.apiBaseURL` reads `BackendModeStore.current.defaultBaseURL`.

`SSRFGuard` constrains **only Layer A** (the server's outbound calls). It does
**not** apply to Layer B (the client picking its own destination server).

## Layer A — BYO Hermes transports

| Transport | Status | Notes |
|---|---|---|
| Cloudflare Tunnel | ✅ done | Recommended; verified e2e 2026-06-06. No domain/ports needed, free HTTPS. |
| Raw IP + token | ✅ done | Allowed; `http://` warned in-app. Operators can hard-block via `BYO_HERMES_REQUIRE_HTTPS=true`. |
| Domain + Nginx/Caddy | ✅ done | Cleanest for production; prod itself runs Caddy. |
| Tailscale | ⚠️ self-host only | Works only when the **LuminaVault server** is on the same tailnet. The **managed** cloud server can't reach a private tailnet, and `SSRFGuard` blocks private ranges — by design. |

## Layer B — `BackendMode` (iOS client → LuminaVault server)

| Mode | Status | Resolution |
|---|---|---|
| `hosted` | ✅ live | `Config.hostedAPIBaseURL` (`api.luminavault.fyi`). |
| `localhost` | ✅ dev | `http://localhost:8080` (DEBUG default). |
| `byo` | ✅ wired | User URL via `BYOServerStore`; `ServerConnectionView.testAndSave()` validates + health-probes, then `setMode(.byo)` forces re-login. |
| `tailscale` | ✅ wired | User tailnet host via `TailscaleServerStore`; `testAndSaveTailscale()` validates + probes, then `setMode(.tailscale)`. WireGuard encrypts → plain `http://` accepted (transport warning suppressed). |

Mode switches post `BackendModeStore.modeChangedNotification`, which the app
root observes to force a clean re-login (the old session token belongs to the
old endpoint).

## Infrastructure

| Item | Status | Notes |
|---|---|---|
| Production VPS | ✅ live | `167.233.30.48`, Caddy (TLS + HTTP/2), images from GHCR. |
| Hermes host VPS | ✅ live | `78.46.192.73` (separate box). |

## Known caveats / out of scope

- Managed-mode Tailscale for BYO Hermes is **not** supported (private-range
  `SSRFGuard` block, by design) — self-host the LuminaVault server to use it.
- iOS does not expose tailnet state to apps, so the tailnet host is entered
  manually; there's no automatic reachability detection.
