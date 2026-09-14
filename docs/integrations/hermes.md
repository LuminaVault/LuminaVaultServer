# Your own Hermes

Point LuminaVault at a Hermes you run yourself instead of the managed one.

This page is the **client** half: what to click, in which app, and what the
errors mean. For running and exposing the Hermes itself — `api_server` env,
systemd, Docker, Cloudflare Tunnel, nginx — see [`../byo-hermes.md`](../byo-hermes.md).

---

## Three things, not one

This is the single biggest source of confusion, so it comes first. "Connecting
your Hermes" is up to **three separate links**, each configured in its own
place, each powering different features.

| | Port | Where you configure it | What stops working without it |
|---|---|---|---|
| **Gateway** (`api_server`) | 8642 | Web *and* iOS | Chat, agent runs, skills listing |
| **Dashboard** | 9119 | **Web only** | Remote cron, vault import, skill writes |
| **Mirror** | — | Web only (buttons) | Nothing — it is the thing that *uses* the two above |

Your phone never talks to Hermes. The **LuminaVault server** dials your box, on
every call that needs it:

```
iPhone / browser ──https──> LuminaVault server ──(your URL)──> your Hermes
                                   │
                                   └── nothing configured? → managed Hermes
```

That matters for reachability: the address has to work **from wherever the
LuminaVault server runs**, not from your laptop.

---

## Before you start

- A Hermes running `hermes gateway run` with the **`api_server` adapter enabled**.
  The interactive TUI and `hermes proxy start` do **not** serve `/v1` — this is
  the step most people miss. [`../byo-hermes.md`](../byo-hermes.md#run-a-hermes-that-serves-the-v1-api)
  has the env block.
- Its URL, reachable from the LuminaVault server.
- Your `API_SERVER_KEY`, which you will paste as a Bearer token.
- For the dashboard half: the dashboard's own URL and token, and a dashboard
  **bound to `127.0.0.1`** — see [the dashboard section](#2-the-dashboard-web-only).

Verify the box answers before you touch either app:

```bash
curl -s -H "Authorization: Bearer $API_SERVER_KEY" https://your-hermes/v1/models
# → a JSON model list. HTML means you hit the dashboard, not the API server.
```

---

## 1. The gateway

### On the web

1. Sidebar → **Settings** (bottom group, *Workspace*).
2. In the Settings rail, under **Connections**, click **Hermes server**.
   On a phone, tap the section button at the top, then **Hermes server**.
3. You will see **Managed Hermes** — "You're on LuminaVault managed Hermes —
   nothing to configure." Click **Connect my own Hermes**.
4. Fill in **Base URL**, e.g. `https://hermes.yourdomain.com`.
5. Set **Authentication** to **Bearer token** and paste your `API_SERVER_KEY`.
   The other options are **None** and **Username & password**.
6. Click **Save**. The page confirms: *"Saved. Run Test to verify reachability."*
7. Click **Test again**.

Note that **Save and Test are two separate actions on the web.** Saving does not
verify anything. There is no "Save & verify" button in the browser — that is the
iOS label, and older docs used it for both.

Once configured the page shows **Connected Hermes** with **Base URL**,
**Authentication**, **Verified**, and three buttons: **Test again**,
**Update credentials**, **Disconnect**.

### On iOS

1. Tab bar → **More** → **Settings**.
2. Scroll to **Manage Connections** → tap **Hermes Server**.
3. Tap **Connect my own Hermes →**.
4. Optionally set **Name** ("My VPS").
5. Fill **Hermes URL**.
6. Set **Authentication** to **Bearer token**, paste your `API_SERVER_KEY` into
   **Token**.
7. Tap **Save & verify** — on iOS this *is* both actions: it `PUT`s the config
   and then immediately probes it.

There is also a shortcut: tap the Hermie mascot in the header → **Hermes**.
And new users are offered this during onboarding, via **Set up now →**.

If the probe fails, **iOS still saves the config** and shows the state as
unverified. A failed test does not mean nothing was stored.

### What the errors mean

Both clients map the same server codes. The wording differs slightly; the cause
does not.

| Code | What actually happened |
|---|---|
| `ssrf_rejected` | The address resolved to something the guard blocks — private, loopback, or link-local. See [SSRF](#what-gets-rejected-and-why). |
| `unreachable` | DNS resolved but nothing answered from where the server runs. |
| `timeout` | It answered too slowly. |
| `http_4xx` | Hermes rejected the request — usually the wrong port (9119 instead of 8642) or a token that is not `API_SERVER_KEY`. |
| `http_5xx` | Hermes itself errored. Check its logs. |
| `tls_error` | Certificate problem. Self-signed certificates are not accepted. |
| `decrypt_failed` | Stored credentials could not be read. Re-enter the token and save again. |

---

## 2. The dashboard (web only)

Skills writes, scheduled jobs and vault access do **not** go through the
gateway. They go through the Hermes **dashboard**, which is a different service
on a different port with its own token.

> **iOS cannot do this.** There is no dashboard form anywhere in the iPhone app
> — the endpoint is not even declared in its API layer. If you set up Hermes
> entirely on iOS you will have working chat and silently no cron, no vault
> import and no skill writes. Finish on the web.

### The loopback rule

Hermes only accepts a static bearer token on its dashboard when the dashboard is
**listening on `127.0.0.1`**. Bound to any other address it offers its OAuth
sign-in page instead, and **no token will get past it**.

So: bind the dashboard to loopback, and publish it through your own TLS reverse
proxy or tunnel. Paste that public URL here. If you skip this you will get
*"Saved, but your dashboard is behind its sign-in page."*

### Steps

1. Settings → **Hermes server** (you must already have a gateway saved — the
   dashboard card only renders once the gateway is configured).
2. Scroll to **Hermes dashboard**.
3. Fill **Dashboard URL** — the public HTTPS URL of your loopback-bound dashboard.
4. Fill **Dashboard token**.
5. Click **Link dashboard**.

The token is sealed on the server and never sent back to the page. No screen can
show it again — keep your own copy.

Saving is also a probe. On success: *"Your Hermes accepted the token and answered
with N scheduled jobs."*

---

## 3. The mirror (web only)

Once both halves are linked, the **Hermes mirror** card copies your Hermes
skills, jobs, vault and sessions into LuminaVault. A background worker also
pulls every 15 minutes on its own.

Buttons: **Sync now**, **Create vault on my Hermes**, **Import vault**,
**Import past sessions**, **Install nightly compile**, and **Import from path**
for an existing vault directory.

Every *write* action needs a dashboard whose probe came back as a working bearer.
Without one they are disabled and the card says so: *"Vault, session and job
actions need a dashboard that accepts the token. Sync still reads skills through
the API server."*

---

## What gets rejected, and why

User-supplied URLs are an SSRF surface: without a guard, anyone could point
their "Hermes" at `169.254.169.254` or an internal admin service and have the
server fetch it for them. `SSRFGuard` (`Sources/App/Settings/SSRFGuard.swift`)
resolves the host and rejects loopback, RFC1918, link-local and metadata
addresses — **on every request, not just on save**, because a name that resolved
publicly at save time can resolve privately later.

Two deployment flags widen it:

| Env var | Default | Effect |
|---|---|---|
| `BYO_HERMES_ALLOW_PRIVATE` | `false` | `true` allows private/loopback ranges. Dev only — with it on, any signed-in user can aim a gateway at your internal services. |
| `BYO_HERMES_REQUIRE_HTTPS` | `true` outside dev | Rejects `http://` URLs. |
| `BYO_HERMES_ALLOW_TAILNET_HTTP` | `true` | Waives the HTTPS rule for hosts whose every resolved address is Tailscale (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`), and exempts those addresses from the private-range block. |

### The tailnet warning is wrong here

Both clients show a warning when you type a `100.x` or `*.ts.net` address:

> Web: *"The managed cloud API cannot reach 100.x or \*.ts.net — use a Cloudflare
> Tunnel or a public HTTPS hostname instead."*
>
> iOS: *"LuminaVault's server isn't on your tailnet, so it can't reach it."*

**That is true for a generic deployment and false for LuminaVault's own
cluster.** The cluster node is on the tailnet and `cluster/coredns/custom.yaml`
carries a static entry, so a tailnet hostname both resolves and routes from the
API pod. Verified from inside `api-production`:

```
getent hosts hermes-vps-2.tail562587.ts.net  → 100.105.117.67
GET :8642/v1/models                          → HTTP/1.1 401 Unauthorized
```

A `401` is the healthy answer — reachable, wants the key.

It also *passes* the guard, for the reason in the table above: a Tailscale
address takes the `allowTailnetHTTP` branch, which both waives the HTTPS
requirement and skips the private-range check.

**What does not work is the in-cluster name.** `http://<svc>.horus.svc.cluster.local:8642`
resolves to a ClusterIP in `10.43.0.0/16`, which is RFC1918, which
`BYO_HERMES_ALLOW_PRIVATE=false` rejects — and it is `http://`, which
`BYO_HERMES_REQUIRE_HTTPS` rejects independently. Use the tailnet name.
`LuminaVaultInfra/apps/loci/data/hermes-egress.yaml` carries the per-app table.

---

## Verifying it actually works

1. Settings → **Hermes server** → **Test again**. Expect a verified timestamp.
2. Scroll to **Hermes mirror** → **Sync now**. Expect
   *"Synced — N skills, N jobs, N vault files."* with **non-zero** counts.
3. Check **Last sync** is within the last 15 minutes and **Last problem** is empty.

Non-zero counts are the real test. `lastStatus: ok` with zeros everywhere used to
be the signature of a silent failure — see below.

---

## Known limits

- **No dashboard form on iOS.** Gateway only. Finish on the web.
  (`PUT /v1/me/hermes/cron/config` is not declared in the iOS API layer at all.)
- **The tailnet warning is wrong for this deployment** — see above. It is
  advisory and never blocks saving, so paste the address anyway.
- **A failed test still saves your config on iOS.** The state shows unverified.
- **Gateway status never advances past "configured"** for messaging gateways
  reached through Hermes — Hermes exposes no gateway-admin HTTP API, so `Test`
  can only probe `/v1/health`.
- **Cron pause / resume / delete are web-only.** iOS lists and creates cron jobs
  but declares no endpoint for the other three.
- **No "re-probe my Hermes" button.** `/v1/me/hermes/capabilities?refresh=true`
  exists and is declared on iOS, but no screen ever passes `refresh: true`.
- **Silent mirror fallback — fixed, worth knowing.** Until
  `HermesMirrorTransportFactory` stopped swallowing the resolver error, a
  configured-but-unusable gateway fell through to a filesystem transport on
  LuminaVault's own disk and reported `lastStatus: ok` with zero counts and no
  error. If you are reading an older deployment's mirror status, zero counts
  meant "broken", not "empty".
