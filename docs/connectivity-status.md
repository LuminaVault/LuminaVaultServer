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
| Tailscale | ✅ self-host only | Works when **both** the LuminaVault server and Hermes are on the same tailnet. Paste `http://<magicdns>:8642` or `http://100.x:8642` + Bearer (`API_SERVER_KEY`). See [Production Hermes strategy](byo-hermes.md#production-hermes-connection-strategy). **Managed SaaS** (`api.luminavault.fyi`) cannot reach private tailnets — use Cloudflare Tunnel or public HTTPS instead. Verified e2e 2026-07-05 (self-host). |

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
| Production API (Compose) | ✅ live | `167.233.30.48` / `api.luminavault.fyi`, Caddy TLS, GHCR images. Primary prod path until k3s cutover. |
| Production API (k3s) | 🔄 staging | ArgoCD stack in `LuminaVaultInfra/`; production cutover pending DNS flip per `docs/runbook-cutover.md`. |
| Managed Hermes (in-cluster) | ✅ configured | REST `api_server` on `:8642` in `apps/hermes/hermes.yaml`; API dials `http://hermes.<ns>.svc.cluster.local:8642` via `HERMES_GATEWAY_URL`. |
| Legacy Hermes VPS | ⚠️ decommission | `78.46.192.73` — superseded by in-cluster Hermes; destroy per incident/cutover runbooks when confirmed idle. |

## Known caveats / out of scope

- Managed-mode Tailscale for BYO Hermes is **not** supported — the managed
  server is not a member of your tailnet, so tailnet IPs are unroutable and
  MagicDNS names are unresolvable from it. (Not an `SSRFGuard` block:
  100.64.0.0/10 is deliberately not classified as private.)
- A **Dockerized** self-hosted server may not resolve `*.ts.net` names through
  the container's DNS. Use host networking, or enter the node's `100.x.y.z`
  Tailscale IP instead of the MagicDNS name.
- iOS does not expose tailnet state to apps, so the tailnet host is entered
  manually; there's no automatic reachability detection.
