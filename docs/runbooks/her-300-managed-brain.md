# Managed brain via OpenRouter

## Current contract

LuminaVaultServer owns managed-model policy. The default route is:

```text
LuminaVaultServer → OpenRouter → deepseek/deepseek-v4-flash
```

Users do not provide a key in managed mode. The API reads the platform key from
`LLM_PROVIDER_OPENROUTER_APIKEY`; never put that key in iOS, web, a commit, or a
support transcript. The central Hermes deployment remains the agent runtime and
gateway fallback, but the active Cerberus managed route can call OpenRouter
directly through the Swift provider adapter.

Managed clients select only `mode: managed`. For backward compatibility the
wire request still contains provider/model fields, but the server ignores them,
persists the configured managed route, and returns the effective route. This
allows model changes without an iOS or web release.

## Configuration

Set these on LuminaVaultServer:

```env
LLM_PROVIDER_OPENROUTER_APIKEY=<rotated-platform-key>
LLM_PROVIDER_OPENROUTER_BASEURL=https://openrouter.ai/api/v1
HERMES_DEFAULT_MANAGED_MODEL=deepseek/deepseek-v4-flash
HERMES_MANAGED_PROVIDER_HINT=openrouter
CERBERUS_EXECUTION_MODE=active
CERBERUS_PARALLEL_ENABLED=false
```

The model variable is optional because the code default is the same slug, but
production should set it explicitly so the deployed policy is visible in
configuration. Changing it requires an API restart and reconciliation of
already-persisted managed router profiles.

The official OpenRouter model page is
<https://openrouter.ai/deepseek/deepseek-v4-flash>. Pricing recorded in the
router catalog on 2026-07-22 is $0.09/M input and $0.18/M output. Provider
pricing remains authoritative and must be reviewed periodically.

## Verification

Do not print or echo the key. Verify only that the environment variable is
present, then exercise the authenticated product path:

1. `GET /v1/me/preferences/llm` for a new account returns:

   ```json
   {
     "mode": "managed",
     "primaryProvider": "openRouter",
     "primaryModel": "deepseek/deepseek-v4-flash",
     "fallbackChain": []
   }
   ```

2. Send a deliberately stale managed PUT. The response must still be the
   canonical DeepSeek route:

   ```json
   {
     "mode": "managed",
     "primaryProvider": "anthropic",
     "primaryModel": "stale-client-model",
     "fallbackChain": []
   }
   ```

3. Send a non-streaming and streaming chat from staging.
4. Confirm router telemetry records `openRouter` and
   `deepseek/deepseek-v4-flash` without logging prompts or credentials.
5. Confirm the OpenRouter dashboard records the requests and platform budget.

An unfunded key can validate deployment wiring only up to provider rejection;
it cannot prove a successful completion. Fund staging before declaring the
managed path production-ready.

## BYOK regression

LLM brain `mode: byok` is available on any chat-capable tier (Trial, Pro,
Ultimate). This is separate from the Ultimate-only `privacyBYOKey` privacy
setting in billing.

With a test account on any tier:

1. Store and test a user-owned provider credential.
2. Set `mode: byok` with an explicit primary and fallback chain.
3. Confirm the user credential is used and managed allowance is not debited.
4. Remove every user key and confirm BYOK fails closed instead of using the
   platform OpenRouter key. Clients should surface `403 byok_keys_required`
   with CTA hints `add_key` and `switch_to_managed`.

## Rollback

Set `HERMES_DEFAULT_MANAGED_MODEL` to the previous supported OpenRouter slug,
restart the API, and run the managed-profile reconciliation. Do not restore a
hard-coded model in either client.

## Operational notes

- Keep an OpenRouter key-level spending limit at or below the platform monthly
  ceiling.
- Alert on HTTP 402, managed fallback volume, and budget reservation failures.
- Keep `model.max_tokens` bounded where Hermes is the executing gateway; it is
  independent of the model context window.
- Run `make hermes-sync-context` after changing the model used by Hermes so its
  primary and compression context metadata remain above Hermes' 64K minimum.
