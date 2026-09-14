# Connect your brain

"Brain" is whatever model answers you. LuminaVault ships with one, and you can
replace it with your own key, your own Hermes, or a model running on your own
machine.

You do not have to choose now. The managed brain works out of the box, and every
option below is reversible.

---

## Which one do you want?

| You want | Pick | Where |
|---|---|---|
| It to just work | **Managed** | Nothing to do — this is the default |
| To use your own API key | **BYOK** | [below](#byok-your-own-api-key) |
| To run the model yourself, on your own box | **BYO Hermes** | [below](#byo-hermes-your-own-server) |
| Prompts never to leave your machine | **Local / hybrid** | [below](#local-and-hybrid) |
| Grok, using your SuperGrok subscription | **Linked account** | [linked-accounts](../integrations/linked-accounts.md) — iOS only |

These are not exclusive. A common setup is a BYOK key for cloud work plus a
local model for anything private, with the hybrid profile deciding per turn.

---

## Managed (the default)

Nothing to configure. Chat shows **LuminaVault Brain · Auto** and there is no key
to add. If you have changed away and want to come back:

**Web** — Settings → **Intelligence** → **Brain** tab → **Managed** → **Save preferences**.

**iOS** — Settings → **Manage Connections** → **Intelligence** → under **Brain**, pick **Managed**.

---

## BYOK: your own API key

Nine providers. Anthropic, OpenAI, OpenRouter, Gemini, xAI, NVIDIA NIM, Nous,
Ollama, and Custom for anything OpenAI-compatible.

**If you are unsure which, use OpenRouter.** One key reaches many models, and it
is the only key that unlocks **Auto (Smart)** routing.

### Web

1. Sidebar → **Settings** → **Intelligence**.
2. **Brain** tab → **Brain mode** → **Bring your own keys** → **Save preferences**.
3. Click the **Keys & models** tab.
4. Pick a **Provider** and a **Model**.
5. Paste the **API key**.
6. **Test connection** → expect *"Connected (\<model\>)."*
7. **Save model settings**.

### iOS

1. **More** → **Settings** → **Manage Connections** → **Intelligence**.
2. Under **Brain**, choose **My API Keys**.
3. Scroll down and tap **Manage API Keys**.
4. Tap your provider.
5. Fill **API key**.
6. Toolbar **Done** → **Test connection**, then **Save**.

**The key fields do nothing until you switch the mode.** On both clients the
editors are visibly disabled in Managed mode, and the explanation is a small
footnote. If the screen looks broken, that is why.

Full reference, including fallback chains, key pools and the routing rules:
[integrations/llm-providers.md](../integrations/llm-providers.md).

---

## BYO Hermes: your own server

Runs the whole agent — routing, skills, memory — on a box you control.

This is the most involved option and it has a prerequisite the app cannot do for
you: a Hermes serving its **`api_server`** HTTP API on port 8642, reachable from
wherever the LuminaVault server runs. [`../byo-hermes.md`](../byo-hermes.md) is
the setup guide; a Cloudflare Tunnel is the easiest way to expose it.

Once that is running:

**Web** — Settings → **Hermes server** → **Connect my own Hermes** → fill
**Base URL**, set **Authentication** to **Bearer token**, paste your
`API_SERVER_KEY` → **Save** → **Test again**.

**iOS** — Settings → **Manage Connections** → **Hermes Server** →
**Connect my own Hermes →** → same fields → **Save & verify**.

Two things to know before you start:

- **Port 8642, not 9119.** 9119 is the Hermes dashboard. Pointing at it gives a
  confusing 4xx, because it answers — just not with what we asked for.
- **iOS can only do half of it.** There is no dashboard form on iPhone, so cron,
  vault import and skill writes will not work until you finish on the web.

Full reference, including the dashboard and mirror:
[integrations/hermes.md](../integrations/hermes.md).

---

## Local and hybrid

Run a model on your own machine — Ollama, LM Studio, MLX, or anything
OpenAI-compatible — and decide per turn whether it or the cloud answers.

**Web** — Settings → **Intelligence** → **Brain** tab → **Hybrid execution**.
**iOS** — Settings → **Intelligence** → **Hybrid execution**.

1. Choose an **Execution profile**:
   - **Private** — local only. Nothing leaves your machine.
   - **Balanced** — local preferred, cloud as backup.
   - **Quality** — cloud preferred, local as backup.
2. Choose a **Local server** and fill **Endpoint URL** (e.g. `http://127.0.0.1:11434`)
   and **Model** (e.g. `qwen3:0.6b`).
3. **Test local model**.
4. Save.

The fallback toggles are profile-specific by design: **Allow local fallback**
only applies in Quality, **Allow cloud fallback** only in Balanced. Private has
neither, because a fallback would defeat it.

iOS also offers **Use Apple on-device model** — Apple Intelligence, fully on
device, iOS 26 and later.

A `127.0.0.1` endpoint only works here. It is not a URL you can give the
LuminaVault server as a Hermes gateway — the server is not on your machine.

---

## Did it work?

1. Send a message in chat and check you get an answer.
2. Web: Settings → **Connections** → **Test all**.
   iOS: Settings → **Diagnostics** → **Test Connections**.
3. The provider or Hermes row should read **Connected**.

If chat is blocked, the usual cause is BYOK mode with no working key — a base
URL on its own is not a credential for anything except Ollama and Custom.
