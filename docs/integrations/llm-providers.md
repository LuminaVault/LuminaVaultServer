# Model providers (bring your own keys)

Use your own Anthropic / OpenAI / OpenRouter / … key instead of the managed
LuminaVault brain, and control how requests are routed between them.

For *which* models we pick and why, see [`../llm-models.md`](../llm-models.md) —
it is authoritative for strategy. This page is how a user wires one up.

---

## Managed vs BYOK

There are two modes, and the key-entry screen is inert in the first one.

- **Managed** — LuminaVault runs the model. No key, nothing to configure.
  Shown as "LuminaVault Brain · Auto".
- **Bring your own keys (BYOK)** — you supply a provider key. Chat stays blocked
  until you do.

You must switch the mode **before** the key fields become editable. This trips
people up on both clients: the key screen looks broken when it is simply
disabled.

---

## Supported providers

Nine, from `Sources/App/Me/ProviderCatalog.swift`:

| Provider | Needs an API key | Needs a base URL |
|---|---|---|
| Anthropic | yes | — |
| OpenAI | yes | — |
| OpenRouter | yes | — |
| Google Gemini | yes | — |
| xAI | yes, *or* a linked SuperGrok account | — |
| NVIDIA NIM | yes | — |
| Nous Research | yes | — |
| **Ollama** | no | **yes** |
| **Custom (OpenAI-compatible)** | optional | **yes** |

Only Ollama and Custom are usable with no key. For every other provider a bare
base URL is **not** a working credential — the server treats it as unset, which
also means it will not lift the paywall.

Groq, Together, Fireworks, DeepInfra, DeepSeek and Kimi exist as internal
routing targets but are not offered in the provider list. Reach them through
**Custom** with the right base URL.

---

## On the web

### Switch the mode

1. Sidebar → **Settings** → **Intelligence** (group *Intelligence*).
2. On the **Brain** tab, under **Brain mode**, click **Bring your own keys**.
3. Click **Save preferences**.

### Add the key

4. Click the **Keys & models** tab.
5. Under **Primary model**, choose a **Provider**.
6. Choose a **Model** — a dropdown once the provider's catalog loads, otherwise
   free text.
7. Fill **Base URL** if the provider shows one (Ollama, Custom).
8. Paste the **API key**.
9. Click **Test connection**. Expect *"Connected (\<model\>)."*
10. Click **Save model settings**.

Optionally add a **Fallback chain** below — provider + model rows tried in order
when the primary fails.

### Routing

Sidebar → **Router** (or Settings → **Cerberus router**, which leaves settings).
Pick a **Routing policy**, set the **Routing objective** sliders, set
**Monthly guardrails**, and build rules under **Visual rule flow**.

**Auto (Smart)** is hidden unless routing is available — it needs OpenRouter,
either because you are on Managed or because OpenRouter is your primary
provider. The page says so where the card would be.

---

## On iOS

1. Tab bar → **More** → **Settings**.
2. **Manage Connections** → **Intelligence**. (The screen title reads
   **Model Router**, not "Intelligence" — same place.)
3. Under **Brain**, choose **My API Keys**.
4. Scroll to **Manage API Keys** and tap it.
5. Tap a provider to open **Edit provider**.
6. Fill **API key** — or **Host URL** for Ollama, or **Base URL** plus optional
   key for Custom.
7. Toolbar **Done** menu → **Test connection**, then **Save**.

Shortcut: tap the Hermie mascot in the header → **LLM Brain**.

The **Primary** and **Fallback chain** editors on the Intelligence pane are
greyed out at 50% opacity while the mode is **Managed**, with the footer
*"Switch to My API Keys to edit your primary provider."*

### iOS extras

**Round-robin key pools** — add several keys per provider and rotate across them
to spread rate limits. Settings → Intelligence → Manage API Keys →
**Round-robin key pools**. No web equivalent.

**xAI via SuperGrok** — in **Edit provider** for xAI, set **Authentication** to
**Linked xAI account (SuperGrok)** and no separate key is needed. Requires the
linked account from [linked-accounts.md](linked-accounts.md).

---

## Hybrid and on-device execution

Run some or all turns against a local model.

**Web:** Settings → **Intelligence** → **Brain** tab → **Hybrid execution**.
**iOS:** Settings → **Intelligence** → **Hybrid execution**.

| Setting | Options |
|---|---|
| Execution profile | **Private** (local only) / **Balanced** (local preferred) / **Quality** (cloud preferred) |
| Allow local fallback | Quality mode only |
| Allow cloud fallback | Balanced mode only |
| Sync local conversations | Off keeps locally generated turns on that device |
| Local server | Ollama / LM Studio / MLX server / OpenAI-compatible |
| Endpoint URL | e.g. `http://127.0.0.1:11434` |
| Model | e.g. `qwen3:0.6b` |

Then **Test local model** and save.

iOS additionally offers **Use Apple on-device model** — Apple Intelligence,
entirely on device, iOS 26 and later.

Because the *LuminaVault server* is what dials a cloud provider but a *local*
endpoint is on your machine, a `127.0.0.1` endpoint only makes sense for the
hybrid local path. It is not a route to give the server.

---

## Verifying

1. **Test connection** on the provider — expect the model name back.
2. Send a chat message and confirm it answers.
3. Web: Settings → **Connections** → **Test all**. iOS: Settings →
   **Diagnostics** → **Test Connections**. The provider row should read
   **Connected**.

---

## Known limits

- **The key screen is inert in Managed mode**, on both clients, and the reason
  is a footnote rather than anything prominent. Switch the mode first.
- **Auto (Smart) silently disappears** without OpenRouter. The explanatory note
  replaces the card, so if you are not looking for it the policy list just looks
  short.
- **A base URL alone is not a credential** for anything except Ollama and
  Custom. It will not unlock chat and will not lift the paywall.
- **Round-robin key pools are iOS-only.**
- **Provider secret env names have two spellings** server-side — canonical is
  read first, then a legacy spelling, then an alias. If a server-configured
  provider is not picking up its key, check which spelling is set.
- **DeepSeek and Kimi are tagged as CN-region** and are excluded when a tenant
  has the `privacy_no_cn_origin` filter on.
