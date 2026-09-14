# Integrations

Everything a LuminaVault user can connect: their own Hermes, their own model
keys, messaging apps, agent clients, plugins, and the data on their devices.

Each page below answers the same four questions in the same order — what it is,
what you need before you start, how to connect it **on the web**, how to connect
it **on iOS** — and ends with what is known to be broken or missing.

Web means `app.luminavault.fyi`. iOS means the LuminaVault iPhone app. They are
not at parity, and the gaps are called out rather than glossed: if a page says
"not available on iOS", that is a fact about the app today, not a gap in this
documentation.

---

## The one switch that turns all of this off

Almost every integration below is built inside a single `if` in
`Sources/App/App+build.swift:764-1067`, guarded by **`LV_SECRET_MASTER_KEY`**.
Without that env var the controllers are never constructed and their routes
**404** — not 403, not "disabled", just absent. The server logs a warning at
`App+build.swift:1064-1066` and otherwise starts normally.

So: if a whole settings pane is empty, or every call from it 404s, check that
env var before debugging anything else. `docs/runbooks/auth-remaining-setup.md`
covers setting it.

---

## Pages

| Page | Covers |
|---|---|
| [hermes.md](hermes.md) | Your own Hermes: the gateway, the dashboard, and the mirror |
| [llm-providers.md](llm-providers.md) | Bring your own model keys — nine providers, routing, fallbacks |
| [messaging-gateways.md](messaging-gateways.md) | Telegram, Discord, Slack, Email, Matrix, ntfy, Mattermost, WhatsApp, iMessage |
| [agent-connections.md](agent-connections.md) | MCP keys for Claude Code, Codex, Hermes, other clients |
| [plugins-and-connectors.md](plugins-and-connectors.md) | Marketplace, plus Readwise / Raindrop / RSS connectors |
| [linked-accounts.md](linked-accounts.md) | xAI (Grok), Nous Portal, Google Calendar |
| [apple-data.md](apple-data.md) | Health, Calendar, Reminders, Photos, Location, Files |

Existing deep-dives that these pages link to rather than repeat:

- [`../byo-hermes.md`](../byo-hermes.md) — how to run and expose a Hermes that
  serves the `/v1` API. The server-side half of [hermes.md](hermes.md).
- [`hermes-on-ollama.md`](hermes-on-ollama.md) — running Hermes against Ollama.
- [`../llm-models.md`](../llm-models.md) — which models we route to and why.
  Authoritative for provider strategy.
- [`../whatsapp-pairing.md`](../whatsapp-pairing.md) — the WhatsApp QR flow.
- [`../voice-metering.md`](../voice-metering.md) — what transcription records.
- [`../pricing.md`](../pricing.md) — tiers and what each one unlocks.

---

## Everything, at a glance

Connect-it-yourself integrations. **Web** and **iOS** say where the user does
it; "—" means that client has no surface for it at all.

| Integration | What it gives you | Web | iOS | Page |
|---|---|---|---|---|
| **Hermes gateway** (BYO) | Chat, runs and skills served by your own box | Settings → Hermes server | Settings → Manage Connections → Hermes Server | [hermes](hermes.md) |
| **Hermes dashboard** | Remote cron, vault import, skill writes | Settings → Hermes server (second card) | **—** | [hermes](hermes.md) |
| **Hermes mirror** | Copies your Hermes skills/jobs/vault into LuminaVault | Settings → Hermes server (third card) | **—** | [hermes](hermes.md) |
| **Model provider keys** | Your own Anthropic / OpenAI / OpenRouter / … key | Settings → Intelligence → Keys & models | Settings → Manage Connections → Intelligence → Manage API Keys | [llm-providers](llm-providers.md) |
| **Cerberus router** | Per-task routing, budgets, fallback chains | Sidebar → Router | Settings → Intelligence (same pane) | [llm-providers](llm-providers.md) |
| **Hybrid / local model** | Ollama, LM Studio, MLX, or Apple on-device | Settings → Intelligence → Brain | Settings → Intelligence → Hybrid execution | [llm-providers](llm-providers.md) |
| **Telegram** | Talk to your assistant from Telegram | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **Discord** | Same, from Discord | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **Slack** | Same, from Slack | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **Email** | Same, over IMAP/SMTP | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **Matrix** | Same, from Matrix | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **ntfy** | Push notifications to an ntfy topic | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **Mattermost** | Same, from Mattermost | Settings → Messaging gateways | Settings → Messaging Gateways | [messaging-gateways](messaging-gateways.md) |
| **WhatsApp** | Same, via QR device link | Settings → Messaging gateways → WhatsApp | Settings → Messaging Gateways → WhatsApp | [messaging-gateways](messaging-gateways.md) |
| **iMessage (Photon)** | A phone number people can text your assistant on | **—** | Settings → Messaging Gateways → iMessage (Photon) | [messaging-gateways](messaging-gateways.md) |
| **Agent connections** | An MCP key for Claude Code / Codex / Hermes | Settings → Agent connections | Settings → Manage Connections → Agent connections | [agent-connections](agent-connections.md) |
| **Marketplace plugins** | Install reviewed skills and sandboxed tools | Sidebar → Marketplace | Settings → Manage Connections → Plugins | [plugins-and-connectors](plugins-and-connectors.md) |
| **Readwise** | Pull highlights into your vault | Marketplace | Plugins | [plugins-and-connectors](plugins-and-connectors.md) |
| **Raindrop.io** | Pull bookmarks into your vault | Marketplace | Plugins | [plugins-and-connectors](plugins-and-connectors.md) |
| **RSS / Atom** | Follow feeds into your vault | Marketplace | Plugins | [plugins-and-connectors](plugins-and-connectors.md) |
| **Hermes Skills Hub** | Install community skills onto your Hermes | **—** | Settings → Plugins → Hermes Hub | [plugins-and-connectors](plugins-and-connectors.md) |
| **xAI / Grok** | Grok chat, X search, vision, TTS via SuperGrok | **—** | Settings → Manage Connections → Linked Accounts | [linked-accounts](linked-accounts.md) |
| **Nous Portal** | Your personal Nous subscription | **—** | Settings → Manage Connections → Connect Nous Account | [linked-accounts](linked-accounts.md) |
| **Google Calendar** | Schedule context in chat; create events | **—** | Settings → Linked Accounts → Google Calendar | [linked-accounts](linked-accounts.md) |
| **Apple Health** | Sleep, activity, heart rate | **—** | Dashboard → Health → Connect HealthKit | [apple-data](apple-data.md) |
| **Calendar / Reminders / Photos / Location / Files** | Device data Lumina may read | Settings → Data access (consent only) | Settings → Account & Data → Data Access | [apple-data](apple-data.md) |
| **Web sign-in approval** | Approve a browser session by scanning its QR | *(shows the QR)* | Settings → System & Advanced → Approve Web Sign-In | — |
| **Sign-in providers** | Apple, Google, X, passkey, phone, email | Login screen | Login screen | — |

Server-configured, not user-connected — listed so you know they exist and are
*not* something a user wires up: transcription (`docs/voice-metering.md`), TTS,
vision embeddings, APNs push (`docs/apns-setup.md`), RevenueCat billing
(`docs/pricing.md`), Hermes self-update (needs an admin token).

---

## Known limits across the whole surface

These are current defects, not design. Each is repeated on the relevant page.

- **iOS cannot link a Hermes dashboard.** It stores only the gateway half.
  A user who sets up BYO Hermes entirely on iPhone gets chat, and gets no cron,
  no vault import, no skill writes, with nothing on screen saying why. They have
  to finish on the web. See [hermes.md](hermes.md#known-limits).
- **The tailnet warnings in both clients are wrong for this deployment.** Both
  say the managed API cannot reach a `100.x` or `*.ts.net` address. For
  LuminaVault's own cluster that is false — the node is on the tailnet and
  CoreDNS carries a static entry. See [hermes.md](hermes.md#the-tailnet-warning-is-wrong-here).
- **Google Calendar, Grok and Nous Portal have no web click-path.** The server
  emits connection rows for all three, and the web app has no route for them, so
  they render as dead text. iOS-only, for now.
- **iMessage (Photon) has no web click-path** and is missing from `openapi.yaml`
  entirely, so the generated web types do not know the gateway exists.
- **`/settings/plugins` on web installs nothing.** Despite its description it
  has one button, Refresh. Installing happens in Marketplace.
- **MCP rejects any client that sends an `Origin` header.** `MCPOriginGuard` is
  constructed with an empty allowlist, so browser-based MCP clients get 403.
  See [agent-connections.md](agent-connections.md#known-limits).
- **Messaging gateway status never says "verified" for the gateway itself.**
  Hermes exposes no gateway-admin API, so `Test` only probes your Hermes health.
- **Passkeys are not production-ready** — see `docs/her-216-followups.md` for
  the blocking list.
