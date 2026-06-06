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
OpenAI-compatible HTTP API. Two common Hermes setups do **not** expose it:

- `hermes` (the interactive TUI) reads your config directly — no HTTP server.
- `hermes gateway run` on bare metal is the **messaging** gateway (Telegram,
  Discord, WhatsApp…). It does **not** serve `/v1`.

The `/v1` HTTP API is served by the **Hermes Docker image** (an API server on
`:8642`, authenticated with `API_SERVER_KEY`). Run that image with your existing
config + provider credentials mounted:

```yaml
# docker-compose.yml — Hermes API server
services:
  hermes:
    image: ghcr.io/nousresearch/hermes-agent:latest   # or your pinned tag
    restart: unless-stopped
    environment:
      # The Bearer token LuminaVault sends. Generate a long random string.
      API_SERVER_KEY: ${HERMES_API_SERVER_KEY:?set a strong token}
    volumes:
      # Your working config + provider keys / OAuth tokens (deepseek, openrouter,
      # nous, xai-oauth, …). This is the same ~/.hermes you use in the TUI.
      - ./hermes-data:/root/.hermes
    ports:
      - "127.0.0.1:8642:8642"   # bind localhost; expose via the TLS proxy below
```

Verify the API is up (from the host):

```sh
curl -H "Authorization: Bearer $HERMES_API_SERVER_KEY" \
     http://127.0.0.1:8642/v1/models      # → JSON model list (not HTML)
```

If you get the **dashboard HTML** instead of JSON, you hit the web UI
(`hermes dashboard`, default `:9119`) — that is **not** the API. Use the
`:8642` API server above. (Also: do not leave the dashboard on
`0.0.0.0 --insecure` — it has no auth.)

> The default `model.default` + `fallback_providers` in your mounted config drive
> what the API answers with (e.g. `deepseek-chat` + nous/openrouter/xai-oauth).

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
        proxy_pass http://127.0.0.1:8080;   # your Hermes container/port
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

## Cloudflare Tunnel (no port-forwarding)

Works behind CGNAT / home networks with no open inbound ports and gives you
HTTPS automatically:

```sh
cloudflared tunnel login
cloudflared tunnel create hermes
cloudflared tunnel route dns hermes hermes.yourdomain.com
cloudflared tunnel --url http://127.0.0.1:8080 run hermes
```

Paste the resulting `https://hermes.yourdomain.com` into the app.

---

## Public IP / `http://` (advanced, discouraged)

A bare public IP (`http://203.0.113.5:8080`) or plain `http://` is **allowed**
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
| Bearer token | `Authorization: Bearer <token>` | Hermes expects an API key |
| Username & password | `Authorization: Basic <base64>` | Hermes is behind HTTP Basic auth |

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

## Future work: BYO LuminaVault server

This guide covers hosting your own **Hermes**. Pointing the iOS app at your own
**LuminaVault API server** (e.g. `https://facorreiavault.com`) is a separate
feature that is **not yet wired** — the in-app "BYO endpoint" backend-mode picker
currently falls back to the managed API and ignores a custom URL. Tracked
separately.
