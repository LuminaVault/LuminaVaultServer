# HER-300 — Managed default brain (Qwen2.5-72B via OpenRouter)

## What it does
New users who accept "Use LuminaVault Default" on the "Choose Your Brain"
onboarding screen route their chat calls through:

  LuminaVaultServer → Hermes container (VPS) → OpenRouter → Qwen2.5-72B

No user-provided API keys are involved on the managed path.

## VPS side — Hermes container (`hermes-bot` on `78.46.192.73`)

1. Add the OpenRouter API key to Hermes' `.env`:

   ```bash
   ssh root@78.46.192.73
   nano ~/.hermes/.env
   # Add (or replace the OPENROUTER_API_KEY line):
   OPENROUTER_API_KEY=<rotated-key-from-https://openrouter.ai/keys>
   ```

   NEVER commit this key anywhere in git. If it ever ends up in a commit,
   PR, chat, or screenshot, rotate it immediately.

2. Flip the default model + provider in Hermes config:

   ```bash
   nano ~/.hermes/config.yaml
   ```

   Change the `model:` block to:

   ```yaml
   model:
     default: qwen/qwen-2.5-72b-instruct
     provider: openrouter   # was 'privider: xai-oauth' — typo + wrong provider
   ```

   Leave `fallback_providers` as-is so failover paths still work.

3. Restart Hermes:

   ```bash
   systemctl restart hermes-bot     # or `docker restart hermes-agent` if containerised
   ```

4. Smoke-test from the VPS shell:

   ```bash
   hermes chat --model qwen/qwen-2.5-72b-instruct "ping"
   ```

   Should return a Qwen reply, not a 401 / model-not-found.

## LuminaVaultServer side

Set the matching env vars on the LVS container so the iOS UI labels
match what Hermes will actually serve:

```
HERMES_DEFAULT_MANAGED_MODEL=qwen/qwen-2.5-72b-instruct
HERMES_MANAGED_PROVIDER_HINT=openrouter
```

Mismatch is not a hard failure — the iOS UI just shows a stale model
name.

## Cost guard

OpenRouter pricing for Qwen2.5-72B as of writing: $0.36/M input, $0.40/M
output, 131K ctx, 8K max output. Anomalous spend should surface in the
HER-134 EmbeddingUsage cost dashboard once chat-token metering lands; for
now, watch the OpenRouter billing page directly.
