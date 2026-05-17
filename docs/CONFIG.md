# Configuration & Environment Variables

LuminaVaultServer reads configuration through Apple's [swift-configuration](https://github.com/apple/swift-configuration) framework. Keys are spelled `camelCase.dot.path` in code (`ConfigKey("hermes.gatewayUrl")`), and the framework resolves them against env vars in `SCREAMING_SNAKE_CASE` (so `hermes.gatewayUrl` ↔ `HERMES_GATEWAY_URL`).

## Sources of truth

| File | Purpose |
| --- | --- |
| `.env.example` | **Canonical contract.** Every variable the server reads should appear here (with a safe default or an explicit `# REQUIRED` comment). Committed to git — do not put secrets in this file. |
| `.env` | Local-dev copy. Git-ignored. Created by `cp .env.example .env`. |
| `docker-compose.yml` | Dev compose stack. References `${VAR:-default}` so an unset var falls back to the default. |
| `docker-compose.production.yml` | Prod compose stack. Uses `${VAR:?required}` for must-haves (`POSTGRES_PASSWORD`, `JWT_HMAC_SECRET`, `CORS_ALLOWEDORIGINS`) so the container fails fast with a clear error if the operator forgot one. |

`.env.example` is the contract; the compose files are the runtime wiring. When you add a new `ConfigKey(...)` read in code, you must update **both** files in the same change.

## Naming convention

- Code reads `ConfigKey("foo.barBaz")`.
- Env var spelling is `FOO_BAR_BAZ` (dot → underscore, camelCase split on word boundary).
- The Configuration framework is lenient and will match both `FOO_BAR_BAZ` and `FOO_BARBAZ`. Prefer the underscored form for new keys — grep-able and consistent with the existing `.env.example`. Existing compose entries (`OAUTH_APPLE_CLIENTID`, `HERMES_GATEWAYURL`) use the concatenated form for legacy reasons; both styles work, but new code should standardise on the split form.

## Required in production

The prod compose declares these as `${VAR:?required}` — container start fails if unset:

- `POSTGRES_PASSWORD`
- `JWT_HMAC_SECRET` (32+ chars; rotate annually)
- `CORS_ALLOWEDORIGINS` (comma-separated list, no spaces inside URLs)

Everything else has a safe default appropriate for a single-tenant deploy. Empty `*_APIKEY` values keep the matching provider unregistered (endpoint returns 503) — that is the intended behaviour, not an error.

## Backdoors to keep out of production

- `PHONE_FIXED_OTP` and `MAGIC_FIXED_OTP` short-circuit the OTP flows for CI/dev. **Never** set them in production — anyone with the value can sign in as any user via those flows. They are intentionally absent from `docker-compose.production.yml`.

## Adding a new variable

1. Add `let foo = reader.string(forKey: "domain.foo", default: ...)` in code.
2. Add a line to `.env.example` under the matching `# --- domain ---` group with a safe default or `# REQUIRED` marker.
3. Add a line to `docker-compose.production.yml` `environment:` block: `DOMAIN_FOO: ${DOMAIN_FOO:-default}` (or `${DOMAIN_FOO:?required}` if production cannot run without it).
4. Add a matching line to `docker-compose.yml` if dev needs it.
5. Document the variable in this file if it has non-obvious semantics.

## Verifying drift

```sh
grep -hE '^[A-Z_]+=' .env.example | cut -d= -f1 | sort -u > /tmp/env-keys
grep -rhE 'forKey:\s*"([a-zA-Z.]+)"' Sources/App/ \
  | sed -E 's/.*"([a-zA-Z.]+)".*/\1/' \
  | awk '{
      out=""
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c == ".") { out=out"_" }
        else if (c ~ /[A-Z]/) { out=out"_"c }
        else { out=out toupper(c) }
      }
      print out
    }' | sort -u > /tmp/code-keys
diff /tmp/env-keys /tmp/code-keys
```

Any code-only key needs an `.env.example` entry. Any env-only key may be safe to delete.
