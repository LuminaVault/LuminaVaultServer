# WhatsApp QR Pairing

Link a user's WhatsApp to their assistant by scanning a QR code — the same way
WhatsApp Web works. No phone number, Meta account, or API key needed.

WhatsApp is the one Hermes messaging gateway with **no enterable credential**.
Telegram / Discord / Slack / Email all take a token the app PUTs and the server
seeds into the tenant's `.env`. WhatsApp instead pairs via **Baileys**
(reverse-engineered WhatsApp Web), driven by the interactive `hermes whatsapp`
CLI that streams a QR to a terminal. This feature surfaces that flow in the app.

## How it works

```
iPhone ──https──> LuminaVault server ──docker exec──> tenant Hermes container
   │                     │                                  │
   │  POST /whatsapp/pair │   runs: script -q -c             │
   │ ───────────────────► │     "hermes whatsapp" /dev/null  │
   │                     │  ◄── stdout (QR block-art) ───────┘
   │  GET .../stream (SSE) │
   │ ◄─── qr / status ─────┤  WhatsAppPairParser → events
   │                     │
   │  [user scans QR on phone: WhatsApp → Linked Devices]
   │ ◄─── linked ──────────┤  session persists on the data volume
```

1. App opens the WhatsApp gateway → **POST `/v1/me/hermes-gateways/whatsapp/pair`**
   → server spawns `hermes whatsapp` in the tenant container, returns a
   `sessionID`.
2. App subscribes to **GET `/v1/me/hermes-gateways/whatsapp/pair/{sessionID}/stream`**
   (SSE). The server tails the CLI's stdout through `WhatsAppPairParser` and
   emits `HermesWhatsAppPairEvent`: `qr` (Unicode block-art, replaced on
   refresh), `status`, `linked`, `error`.
3. User scans the monospaced QR with their phone's **WhatsApp → Settings →
   Linked Devices → Link a Device**.
4. On success the parser emits `linked`; the Baileys session is written to the
   tenant data volume and survives restarts.
5. **DELETE `/v1/me/hermes-gateways/whatsapp/session`** unlinks: deletes the
   session dir and restarts the container so Hermes drops the connection.

### Why the `script` wrapper

`hermes whatsapp` only prints its QR when attached to a TTY. `docker exec -i`
has none, so the backend wraps the command with util-linux `script`, which
allocates a pseudo-TTY and mirrors the session to stdout:

```
script -q -c "/opt/hermes/.venv/bin/hermes whatsapp" /dev/null
```

### Session persistence (important)

Baileys stores its session under `$HOME/.hermes/platforms/whatsapp/session`.
The container sets **`HOME=/opt/data`** (a bind-mounted volume) specifically so
that path lands on durable storage. Without it, the session would be wiped by
the `rm -f` + `run` that `applyGatewayConfig` performs whenever **any** gateway
is applied. If you change the container's `HOME` or volume mounts, update
`LiveWhatsAppPairingBackend.sessionDir` to match.

## Code map

| Concern | File |
|---|---|
| stdout → events parser (pure, unit-tested) | `Sources/App/HermesGateways/WhatsAppPairParser.swift` |
| CLI driver (`docker exec`, PTY, isPaired, unlink) | `Sources/App/HermesGateways/WhatsAppPairingBackend.swift` |
| session orchestration (actor, SSE fan-out) | `Sources/App/HermesGateways/WhatsAppPairingService.swift` |
| SSE response encoder | `Sources/App/HTTP/WhatsAppPairSSEResponse.swift` |
| routes + handlers | `Sources/App/Me/HermesGatewaysController.swift` |
| catalog entry (`pairingKind: .whatsappQR`) | `Sources/App/HermesGateways/HermesGatewayCatalog.swift` |
| wire DTOs | `LuminaVaultShared` ≥ 0.62.0 (`HermesWhatsAppPairEvent`, …) |
| iOS UI | `LuminaVaultClient` `Features/Settings/HermesGateways/WhatsAppPairing{View,ViewModel}.swift` |

---

## ⚠️ Before this is production-ready — operator TODO

The pairing flow is built, builds green, and the parser is unit-tested, but two
checks against a **real Hermes host** are still outstanding. Until they're done,
treat the marker strings below as **informed guesses**.

### 1. Capture real CLI output and pin the parser markers

`WhatsAppPairParser` classifies "linked", "expired", and "error" lines by
matching marker substrings that have **not** been confirmed against a live
`hermes whatsapp` run. On the VPS (`78.46.192.73`):

```bash
# find the tenant container
docker ps --format '{{.Names}}' | grep hermes

# run the CLI interactively and READ the exact wording it prints for:
#   - a fresh QR frame
#   - "device linked / connected" on success
#   - "QR expired / regenerating"
#   - any connection error
docker exec -it <tenant-container> \
  script -q -c "/opt/hermes/.venv/bin/hermes whatsapp" /dev/null
```

Then update the marker arrays in `WhatsAppPairParser.swift`
(`linkedMarkers`, `expiredMarkers`, `errorMarkers`) to the real strings and
extend `WhatsAppPairParserTests.swift` with a captured fixture.

Also confirm the session directory the CLI actually writes to and reconcile it
with `LiveWhatsAppPairingBackend.sessionDir`
(currently `/opt/data/.hermes/platforms/whatsapp/session`).

### 2. End-to-end verification on the VPS

1. Deploy this build.
2. In the app, open the WhatsApp gateway → a QR should render.
3. Scan it from a real phone → status flips to **linked / `verified`**.
4. **Apply a different gateway** (or otherwise recreate the container) and
   confirm the WhatsApp session **survives** — this validates the
   `HOME=/opt/data` persistence fix.
5. Tap **Unlink** → status returns to not-configured and messages stop.

When both pass, the feature is closed.

## Known limitations

- One active pairing session per tenant; starting a new one tears down the old.
- Pairing state is **ephemeral** (in-memory). If the SSE stream drops or the
  server restarts mid-pair, the user just re-opens the sheet and pairs again —
  nothing half-paired is persisted.
- QR is transported as terminal block-art, not a raw payload (the CLI exposes no
  raw-QR flag). It is camera-scannable; the app renders it monospaced.
