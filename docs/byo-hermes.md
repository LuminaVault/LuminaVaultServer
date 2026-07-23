# Bring Your Own Hermes (BYO Hermes)

Point LuminaVault at a Hermes instance you host yourself instead of the managed
default. You keep full control of the box and its configuration — LuminaVault
only needs a **URL** and (optionally) an **auth token**.

> This is the *Hermes AI gateway*, not a LuminaVault API server. Pointing the
> iOS app at your own LuminaVault server is separate and not yet supported — see
> [Future work](#future-work-byo-luminavault-server).

## How it works

```
iPhone ──https──> LuminaVault server ──(your URL)──> your Hermes
                       │
                       └── no config? → managed Hermes (fallback)
```

The **LuminaVault server** (not your phone) connects to your Hermes on every
call that needs it — chat, compile, memory, health correlation. Configure it
once in the app: **Settings → Connections → Hermes Server → Connect my own
Hermes**, enter the URL + auth, then **Save & verify**.

What's stored: your base URL, and your auth header **encrypted at rest**
(AES-GCM via `SecretBox`, per-tenant key). The plaintext token is never returned
by the API after save. Remove it any time with **Disconnect**.

Requirements:

- Reachable from the **public internet** (the server calls it, not your phone).
- HTTPS with a real certificate is strongly recommended.
- Private/LAN/localhost addresses are always rejected (see [SSRF](#whats-blocked-and-why-ssrf)).
- Your Hermes must expose the **OpenAI-compatible HTTP API** (`/v1/models`,
  `/v1/chat/completions`) — see the next section.

---

## Run a Hermes that serves the `/v1` API

**This is the step most people miss.** LuminaVault talks to Hermes over its
OpenAI-compatible HTTP API (`/v1/chat/completions`, `/v1/models`). Setups that do
**not** expose it:

- `hermes` (the interactive TUI) — reads config directly, no HTTP server.
- `hermes gateway run` **without** the `api_server` env (below) — messaging only
  (Telegram/Discord/WhatsApp), no `/v1`.
- `hermes proxy start` — fronts a **single** provider (nous **or** xai) only. It
  does **not** serve your full config, skills, or memory. Don't use it for BYO.

The fix: enable Hermes' **`api_server` adapter**. Then `hermes gateway run` serves
the OpenAI `/v1` API backed by your **full `config.yaml`** — your model routing
(deepseek primary + fallbacks), skills, memory, and agent behavior — authenticated
with `API_SERVER_KEY`. It's env-driven, so it works **system-wide or in Docker**.

Set these (anywhere Hermes reads env — `~/.hermes/.env`, the systemd unit, or the
container `environment:`):

```
API_SERVER_ENABLED=true
API_SERVER_HOST=127.0.0.1      # localhost; expose via the TLS proxy below
API_SERVER_PORT=8642
API_SERVER_KEY=<openssl rand -hex 32>   # the Bearer token you give LuminaVault
API_SERVER_MODEL_NAME=hermes-3          # optional default model label
```

### System-wide install (no Docker)

If Hermes already runs as `hermes-gateway.service`, add a drop-in and restart —
no `config.yaml` edits, no restart loops:

```sh
sudo mkdir -p /etc/systemd/system/hermes-gateway.service.d
sudo tee /etc/systemd/system/hermes-gateway.service.d/api-server.conf >/dev/null <<'EOF'
[Service]
Environment=API_SERVER_ENABLED=true
Environment=API_SERVER_HOST=127.0.0.1
Environment=API_SERVER_PORT=8642
Environment=API_SERVER_KEY=REPLACE_WITH_STRONG_RANDOM
EOF
sudo systemctl daemon-reload && sudo systemctl restart hermes-gateway
```

### Docker Compose

```yaml
services:
  hermes:
    image: ghcr.io/nousresearch/hermes-agent:latest   # or your pinned tag
    command: ["gateway", "run"]
    restart: unless-stopped
    environment:
      API_SERVER_ENABLED: "true"
      API_SERVER_HOST: 0.0.0.0
      API_SERVER_PORT: "8642"
      API_SERVER_KEY: ${HERMES_API_SERVER_KEY:?set a strong token}
    volumes:
      - ./hermes-data:/root/.hermes   # same config + creds the TUI uses
    ports:
      - "127.0.0.1:8642:8642"          # expose via the TLS proxy below
```

### Verify (from the host)

```sh
curl -H "Authorization: Bearer <KEY>" http://127.0.0.1:8642/v1/models
# → JSON model list backed by your config (deepseek, fallbacks, …) — NOT HTML
```

If you get **dashboard HTML**, you hit the web UI (`hermes dashboard`, `:9119`) —
that is **not** the API. Don't leave the dashboard on `0.0.0.0 --insecure` (no
auth). Use the `:8642` api_server above.

---

## What you get over BYO (and what stays in LuminaVault)

| Runs on **your** Hermes (via `/v1`) | Stays in **LuminaVault** |
|---|---|
| Model routing: deepseek primary + fallback chain | Conversation history (Postgres) |
| Skills, agent tools | Vault + memories used for **grounding** (pgvector) injected per prompt |
| Memory (Mnemosyne / native) | Provider/credential rows; Jobs/Kanban/analytics |
| Hermes's own cron jobs (its scheduler, on your box) | |

Connecting BYO routes **new** chats/agent calls to your Hermes — it does **not**
migrate that instance's existing TUI history or cron jobs into the app.

---

## Choose how to expose it

There are several ways to make your Hermes reachable by LuminaVault. **The
easiest (Cloudflare Tunnel / raw IP) work with no domain.** A domain is
*recommended for production* but not required.

| Method | Domain? | HTTPS? | Difficulty | Best for |
|---|---|---|---|---|
| **Cloudflare Tunnel** | No | ✅ | Easy | **Most users — recommended** |
| **Raw IP + token** | No | ❌ | Easy | Testing / power users (with warnings) |
| **Tailscale** | No | ✅ | Medium | Private / advanced, very secure |
| **Domain + Nginx/Caddy** | Yes | ✅ | Medium | Serious self-hosting, cleanest long-term |
| **NPM + domain** | Yes | ✅ | Medium | Optional, if you already run nginx-proxy-manager |

All of them front the same `api_server` (`:8642`) from the previous section.
Pick one below.

---

## Cloudflare Tunnel — recommended (no domain, no open ports, HTTPS)

Works behind CGNAT / firewalls with no inbound ports and gives HTTPS for free.

**Quick tunnel (fastest, ephemeral URL — great for testing):**
```sh
# install once
curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
# run it (keep it alive with systemd-run so it survives your SSH session)
systemd-run --unit=hermes-tunnel --collect \
  /usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8642
# grab the public URL:
journalctl -u hermes-tunnel | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
```
The printed `https://….trycloudflare.com` is your app URL. ⚠️ It **changes** on
restart/reboot and has no uptime guarantee — fine for testing, not production.

**Named tunnel (stable URL — production):** needs a free Cloudflare account + a
domain on Cloudflare. `cloudflared tunnel login`, `create hermes`,
`route dns hermes hermes.yourdomain.com`, then run it pointing at
`http://127.0.0.1:8642` (see below).

Then in the app: URL = the tunnel URL, Auth = **Bearer** `API_SERVER_KEY`.

---

## Tailscale (private, no public exposure)

Put the VPS and — for self-hosted LuminaVault — the LuminaVault server on the
same tailnet. Hermes is reachable at the VPS's Tailscale IP/name with no public
port. Note: this only works when the **LuminaVault server** is on the tailnet
(self-host); the managed cloud LuminaVault can't use it because it isn't a
member of your tailnet — `100.x` addresses are unroutable from it and
`*.ts.net` MagicDNS names don't resolve. (`SSRFGuard` itself does **not**
block Tailscale addresses: 100.64.0.0/10 and fd7a:115c:a1e0::/48 are exempt.)
`tailscale up` on both, then app URL = `http://<vps-tailscale-name>:8642`
(MagicDNS, e.g. `http://hermes-vps.tail562587.ts.net:8642`) or
`http://100.x.y.z:8642` + Bearer key.

Plain `http://` is fine here — WireGuard encrypts the link. This works even
with `BYO_HERMES_REQUIRE_HTTPS=true`: `BYO_HERMES_ALLOW_TAILNET_HTTP`
(default `true`) waives the HTTPS requirement for hosts whose every resolved
address is a Tailscale one. Set it to `false` to force TLS on the tailnet too.

Docker caveat: a containerized LuminaVault server may not resolve `*.ts.net`
through the container's DNS. Use host networking, or enter the node's
`100.x.y.z` IP instead of the MagicDNS name.

---

## Recommended: domain + HTTPS

Put Hermes behind a reverse proxy with a TLS cert on a domain you control
(`https://hermes.yourdomain.com`).

### 1. DNS

Point an `A` record at your VPS public IP.

### 2. TLS cert (Let's Encrypt)

```sh
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d hermes.yourdomain.com
```

### 3. nginx reverse proxy

Hermes chat responses are **streamed (SSE)**. nginx buffers responses by
default, which makes streaming replies arrive all-at-once or stall — the
`proxy_buffering off` + long-timeout settings below are required, not optional.

```nginx
server {
    listen 443 ssl;
    server_name hermes.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/hermes.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/hermes.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8642;   # the api_server port
        proxy_http_version 1.1;

        # --- SSE / streaming survival (required) ---
        proxy_set_header Connection '';     # keep-alive, don't close the stream
        proxy_buffering off;                # stream tokens as they arrive
        proxy_cache off;
        proxy_read_timeout 3600s;           # don't kill long-lived streams at 60s
        proxy_send_timeout 3600s;

        # --- standard proxy headers ---
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    client_max_body_size 50M;   # headroom for large payloads
}
```

If you run Hermes in Docker, make sure it listens on `0.0.0.0` inside the
container so the proxy on the host can reach it.

---

## Cloudflare named tunnel (stable URL, production)

The quick tunnel above is ephemeral. For a permanent `https://hermes.yourdomain.com`
(needs a free Cloudflare account + a domain on Cloudflare):

```sh
cloudflared tunnel login
cloudflared tunnel create hermes
cloudflared tunnel route dns hermes hermes.yourdomain.com
cloudflared tunnel --url http://127.0.0.1:8642 run hermes   # the api_server port
```

Paste the resulting `https://hermes.yourdomain.com` into the app (Bearer = `API_SERVER_KEY`).

---

## Raw public IP + token (easy, with warnings)

A bare public IP (`http://203.0.113.5:8642`) or plain `http://` is **allowed**
but insecure:

- **`http://` sends your auth token in plaintext** — anyone on the network path
  can read it.
- **A raw IP has no certificate** — the connection can't be authenticated and is
  open to man-in-the-middle.

The iOS app shows an explicit warning when you enter such a URL. Only use this
on a trusted network, and prefer rotating to a domain + HTTPS as soon as you can.

Operators can forbid this entirely server-side by setting
`BYO_HERMES_REQUIRE_HTTPS=true`, which rejects `http://` at save time.

> Note: this path is **server → Hermes**, so iOS App Transport Security does not
> apply — plain `http` works here. The risk is purely the plaintext token + lack
> of TLS, not an OS restriction.

---

## What's blocked and why (SSRF)

User-supplied URLs are a Server-Side Request Forgery surface. The server refuses
to call internal targets, both at save time **and** before every outbound
request (DNS-rebinding defense — a hostname that resolved public at save time is
re-checked each call). Always rejected:

- **Loopback** — `localhost`, `127.0.0.0/8`, `::1`
- **Private (RFC1918)** — `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, IPv6 `fc00::/7`
- **Link-local** — `169.254.0.0/16` (incl. cloud metadata `169.254.169.254`), `fe80::/10`
- **Wildcard** — `0.0.0.0`

These blocks are independent of the `http`/`https` choice. (Self-hosters running
Hermes on the *same machine* as LuminaVault can set `BYO_HERMES_ALLOW_PRIVATE=true`
for dev only — never in production.)

---

## Authentication

Choose in the app when connecting:

| Mode | Sent as | Use when |
|------|---------|----------|
| None | — | Hermes is open / unauthenticated |
| Bearer token | `Authorization: Bearer <token>` | Hermes expects an API key — **this is the normal choice**: use your `API_SERVER_KEY` |
| Username & password | `Authorization: Basic <base64>` | Only if a reverse proxy adds HTTP Basic in front of Hermes |

For the `api_server` adapter the auth is the **`API_SERVER_KEY`** as a **Bearer
token**.

> ⚠️ This is **not** your server's SSH login. Never enter your VPS root username /
> password here — it would be forwarded to the endpoint as an `Authorization`
> header (and over plain HTTP, in clear text). If you've done this, set Auth to
> the `API_SERVER_KEY` and rotate the SSH password.

The header is forwarded to your Hermes verbatim. Use HTTPS so it isn't exposed.

---

## Troubleshooting (Save & verify failures)

After saving, the app probes `<your-url>/v1/models` (falling back to `/healthz`).
The error banner maps to:

| Error | Meaning | Fix |
|-------|---------|-----|
| `ssrf_rejected` | URL resolves to a blocked/private range | Use a public address; check DNS |
| `tls_error` | TLS handshake/cert failed | Fix the cert (valid chain, not expired, matches host); avoid bare-IP TLS |
| `timeout` | No response in time | Check the box is up, firewall/port open, proxy reachable |
| `unreachable` | Connection failed | Verify DNS, port, that Hermes listens on `0.0.0.0` |
| `http_4xx` | Auth rejected / endpoint missing | Check the token; confirm Hermes exposes `/v1/models` or `/healthz` |
| `http_5xx` | Hermes errored | Check Hermes logs |
| `decrypt_failed` | Server couldn't decrypt the stored token | Re-enter the token and save again |

---

## Production Hermes connection strategy

Three distinct paths — pick based on **where LuminaVaultServer runs**:

| Deployment | Managed Hermes | User BYO Hermes |
| --- | --- | --- |
| **Managed SaaS** (`api.luminavault.fyi`, k3s) | In-cluster REST: `HERMES_GATEWAY_URL=http://hermes.<namespace>.svc.cluster.local:8642`, Bearer `HERMES_API_KEY` ↔ Hermes `API_SERVER_KEY`. Use `HERMES_GATEWAY_KIND=logging` when API and Hermes use separate PVCs. Chat always uses REST regardless of `HERMES_GATEWAY_KIND`. | Cloudflare Tunnel or public HTTPS + Bearer. **Not Tailscale** — SaaS pods are not on the user's tailnet. |
| **Self-hosted Compose** (single host) | `HERMES_GATEWAY_URL=http://hermes:8642`; `HERMES_GATEWAY_KIND=filesystem` when API and Hermes share the Hermes data volume. | Any transport in the table above. |
| **Self-hosted + remote Hermes** | N/A | **Tailscale (Layer A):** join **both** LuminaVaultServer and Hermes to the same tailnet; URL `http://100.x:8642` or MagicDNS; Bearer = `API_SERVER_KEY`; keep `BYO_HERMES_ALLOW_TAILNET_HTTP=true`. Prefer `100.x` inside Docker if MagicDNS fails. |

### Hermes `api_server` enablement (Nous Hermes agent)

Required env on the Hermes container ([api-server docs](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/api-server.md)):

```env
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_PORT=8642
API_SERVER_KEY=<same as HERMES_API_KEY>
API_SERVER_MODEL_NAME=hermes-3
```

`API_SERVER_CORS_ORIGINS` is not needed for LuminaVault — the server calls Hermes, not the browser.

Verify:

```sh
curl -fsS "$HERMES_URL/health"
curl -fsS -H "Authorization: Bearer $API_SERVER_KEY" "$HERMES_URL/v1/models"
```

---

## BYO LuminaVault server (separate from BYO Hermes)

This guide covers hosting your own **Hermes**. Pointing the iOS app at your own
**LuminaVault API server** (e.g. `https://vault.example.com`) is a **separate,
now-shipped** feature — don't confuse the two.

In the app: **Settings → Server Connection → Backend mode**. Two self-host
modes take a user-entered URL, health-probe it, persist it, and force a clean
re-login against your server:

- **BYO endpoint** — a publicly reachable LuminaVault server URL.
- **Tailscale** — a MagicDNS name / tailnet IP of a LuminaVault server on your
  tailnet. WireGuard encrypts the link, so plain `http://` is fine here.

Note this is the **iOS client → LuminaVault server** hop. It is independent of
the **server → your Hermes** BYO-Hermes connection documented above, and of the
server-side `SSRFGuard` (which only constrains the server's outbound BYO-Hermes
calls, not which server the client talks to).

See [`connectivity-status.md`](connectivity-status.md) for the full
transport-vs-backend-mode status matrix.
