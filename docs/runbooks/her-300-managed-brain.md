# HER-300 — Managed default brain (Qwen2.5-72B via OpenRouter)

## Status

**Code shipped 2026-05-28** across the HER-300 epic (server, shared, iOS). Tracking ticket: [HER-309](https://linear.app/luminavault/issue/HER-309).

The application code is live on `main` in all three repos, but the **managed brain doesn't actually serve a single token until the steps below are executed**. Until then, every "Use LuminaVault Default" tap on the iOS onboarding gate writes `mode: managed` to `user_llm_preferences` and the chat path tries to route through Hermes' default model — which is still `grok-4.3` via `xai-oauth` until we flip it. New users currently get whatever Hermes' fallback chain serves, not Qwen.

This document is the runbook to execute once a production VPS is provisioned.

## What this enables

```
LuminaVaultServer → Hermes container (VPS) → OpenRouter → Qwen2.5-72B-Instruct
```

No user-provided API keys are involved on the managed path — LuminaVault funds the inference with a single OpenRouter key configured on the Hermes container.

## Prerequisites

Before running anything in this runbook:

- [ ] A Hetzner (or equivalent) VPS is provisioned and reachable.
- [ ] Hermes is installed there and running (`hermes-bot` systemd unit, or `hermes-agent` Docker container — both are supported, see step 3).
- [ ] You hold an **unrotated** OpenRouter API key from <https://openrouter.ai/keys>. Any key that was previously shared in a chat, PR, screenshot, or commit must be rotated *before* you proceed. The key value goes onto the VPS only — never in this repo, never in a commit, never in a PR body.
- [ ] You have SSH access (`root` or a sudoer) on the VPS, and `nano` (or `vim`) installed.

## 1. VPS side — Hermes container

The VPS host throughout this runbook is referenced as `78.46.192.73`; substitute your actual host.

### 1a. Add the OpenRouter API key to Hermes' `.env`

```bash
ssh root@78.46.192.73
nano ~/.hermes/.env
```

Add (or replace) this line:

```env
OPENROUTER_API_KEY=<rotated-key-from-https://openrouter.ai/keys>
```

> **NEVER commit this key anywhere in git.** If it ever lands in a commit, PR, chat, or screenshot, rotate it immediately at <https://openrouter.ai/keys>.

### 1b. Flip the default model + provider

```bash
nano ~/.hermes/config.yaml
```

Replace the `model:` block with:

```yaml
model:
  default: qwen/qwen-2.5-72b-instruct
  provider: openrouter      # was 'privider: xai-oauth' — typo + wrong provider
```

Leave `fallback_providers` as-is so failover paths still work when OpenRouter returns 5xx or rate-limits.

Set `context_length` explicitly for this model. Hermes Agent hard-requires a
**≥64K** context window for both the primary `model` and the
`auxiliary.compression` model and refuses the turn otherwise. Hermes auto-detects
`qwen/qwen-2.5-72b-instruct` at only **32,768**, so set both:

```yaml
model:
  # ...
  context_length: 131072
auxiliary:
  compression:
    context_length: 131072
```

`make hermes-sync-context` refreshes these from provider metadata when the
default model changes; after any swap confirm both values clear the 64K floor.
`context_length` is the input window — independent of the `max_tokens` output cap
and of the credit-based 402 below.

### 1b-bis. Limiting output / avoiding OpenRouter 402

OpenRouter pre-authorizes credits for `(prompt_tokens + max_tokens)`. With
`model.max_tokens` unset, Hermes requests the model's **native output ceiling**
(8192 for qwen-2.5-72b). On a low balance OpenRouter returns **HTTP 402**
(*"requires more credits, or fewer max_tokens"*) and the assistant reply comes
back blank. Cap it explicitly:

```yaml
model:
  default: qwen/qwen-2.5-72b-instruct
  provider: openrouter
  base_url: https://openrouter.ai/api/v1
  api_mode: chat_completions
  max_tokens: 1024          # OUTPUT cap — keep reservation under OpenRouter credits
```

`max_tokens` is independent of `context_length`. See `docs/CONFIG.md` for how to
raise/remove the cap as credits or the default model change.

### 1c. Restart Hermes

Pick the one that matches the install:

```bash
# systemd install
systemctl restart hermes-bot

# Docker install
docker restart hermes-agent
```

### 1d. Smoke-test from the VPS shell

```bash
hermes chat --model qwen/qwen-2.5-72b-instruct "ping"
```

Expected: a Qwen reply (anything coherent — usually starts with "Hello", "Pong", or "Hi").

Failure modes:
- `401 Unauthorized` → wrong `OPENROUTER_API_KEY` in `.env`, or Hermes didn't pick it up (restart again).
- `model_not_found` → typo in the model slug; must be `qwen/qwen-2.5-72b-instruct` exactly.
- Network timeout → OpenRouter outage or VPS egress rule blocking `openrouter.ai`.

## 2. LuminaVaultServer side — env vars

Set the matching env vars on the LVS container so the iOS UI labels match what Hermes will actually serve. These are read at boot by `App+build.swift:115-177` and surfaced through the `/v1/me/preferences/llm` GET default response.

```env
HERMES_DEFAULT_MANAGED_MODEL=qwen/qwen-2.5-72b-instruct
HERMES_MANAGED_PROVIDER_HINT=openrouter
```

Wire these into wherever LVS env lives (Docker compose env file, Hetzner cloud-init, GitHub Actions deploy step from HER-272 once that lands). Restart the LVS container after setting.

A mismatch between this and step 1b is not a hard failure — the iOS UI just shows a stale model name in the "Currently powering you" pill. Keep them in sync to avoid confusion.

## 3. iOS simulator smoke test

After steps 1 and 2 are live in production, run this against the production server from a fresh simulator:

1. Wipe the simulator (`xcrun simctl erase all`) to guarantee a fresh signup path.
2. Build + run LuminaVaultClient (iPhone 16 Pro simulator).
3. Sign up with a throwaway email.
4. Complete the conversion funnel (12 steps) → SOUL quiz (5 steps).
5. **You should now land on `ChooseYourBrainScreen`** — the new gate from HER-300/4.
6. Tap **"Use LuminaVault Default"**. Expected: the screen advances to `MainTabView`, no error alert.
7. Verify server state directly:
   ```bash
   curl -H "Authorization: Bearer <token>" https://api.luminavault.app/v1/me/preferences/llm
   ```
   Should return:
   ```json
   {"mode":"managed","primaryProvider":"openRouter","primaryModel":"qwen/qwen-2.5-72b-instruct","fallbackChain":[]}
   ```
8. Verify routing end-to-end: send a chat message from the iOS app. The reply should land. Tail Hermes logs on the VPS:
   ```bash
   journalctl -u hermes-bot -f          # systemd
   docker logs -f hermes-agent          # Docker
   ```
   Look for `model=qwen/qwen-2.5-72b-instruct` in the outbound payload.

### BYOK regression check

Repeat steps 1-5 with a second throwaway account. On step 6, tap **"Use my own API key"** instead. Expected: `ProvidersPaneView` pushed. Enter a real Anthropic / OpenAI key. After saving, `GET /v1/me/preferences/llm` should return `mode: byok`. Send a chat — reply should land via the BYOK provider, not Hermes' default.

### Settings round-trip

In MainTabView → Settings → Intelligence (renamed from "LLM Providers"):

- Segmented Brain Mode picker visible (Managed / My API Keys).
- "Currently powering you" pill shows the active brain.
- Toggle Managed → BYOK → Managed → tap Save → reopen the pane. Values must persist.

## 4. Cost guard

OpenRouter pricing for Qwen2.5-72B-Instruct as of writing:

| | |
|---|---|
| Input | $0.36 / 1M tokens |
| Output | $0.40 / 1M tokens |
| Context window | 131K |
| Max output | 8K |

Once chat-token metering lands (currently scoped under HER-134's `EmbeddingUsage` cost dashboard), anomalous spend will surface there. Until then, watch the OpenRouter billing page directly: <https://openrouter.ai/credits>.

If managed-user volume spikes unexpectedly:
- Pause new signups on the iOS App Store Connect side (HER-271) to stop the inflow.
- Lower the OpenRouter monthly cap or rotate the key to a tighter budget.
- Consider flipping `HERMES_DEFAULT_MANAGED_MODEL` to a cheaper Qwen variant (e.g. `qwen/qwen-2.5-7b-instruct` at ~6× lower per-token cost) and restart LVS — existing managed users will roll over to the new model without any client change because routing reads it at chat time.

## Reference

- Tracking ticket: [HER-309](https://linear.app/luminavault/issue/HER-309) (Done — code shipped; manual ops deferred).
- Server code paths:
  - `Sources/App/Models/UserLLMPreference.swift` — `mode: managed | byok` field.
  - `Sources/App/LLM/Routing/UserPreferenceModelRouter.swift` — short-circuits to `TableModelRouter` when `mode == .managed`.
  - `Sources/App/Me/LLMPreferencesController.swift` — default GET response for users with no row.
  - `Sources/App/Onboarding/OnboardingController.swift` — `brainConfiguredCompleted` latch.
- iOS code paths:
  - `LuminaVaultClient/Features/Onboarding/ChooseYourBrainScreen.swift` — the gate.
  - `LuminaVaultClient/Features/Settings/LLMPreferences/LLMPreferencesPaneView.swift` — Intelligence pane.
