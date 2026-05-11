# Vault export — `GET /v1/vault/export`

HER-91. Streaming `application/zip` of the authenticated user's vault.

## Authentication

Bearer access token. Same `jwtAuthenticator` middleware used by the rest of `/v1/vault`.

## Query parameters

| Name    | Type            | Required | Notes                                                         |
| ------- | --------------- | -------- | ------------------------------------------------------------- |
| `since` | ISO-8601 string | no       | Filters `raw/` files + `memories.json` to entries modified ≥ `since`. |

## Archive layout

```
SOUL.md                # identity manifest (synthesized at export time)
memories.json          # snapshot of the `memories` table for this tenant
raw/<path>             # every file under tenants/<userID>/raw/
```

`SOUL.md` and `memories.json` are always present, even on an empty vault. Soft-deleted files (`raw/_deleted_<ts>_*`) are never included.

## Limits

- Per-user rate limit: 3 requests per 5-minute window (`vaultExportByUser`).
- Hard cap: 4 GiB per entry and 4 GiB per archive (zip32). Larger payloads return `413 Content Too Large`. Zip64 is a follow-up.
- ZIP method: `STORE` only (no compression). Vault contents are markdown + images; deflate would burn CPU for marginal gain.

## Streaming guarantee

The handler never materializes the full archive in RAM:

- Each on-disk file is read in 64 KiB chunks with a streaming CRC-32 and a data-descriptor record after the body.
- `SOUL.md` and `memories.json` are small and held in memory only long enough to checksum + emit.

## curl

```bash
# Full export
curl -fSL \
  -H "Authorization: Bearer $TOKEN" \
  -o vault.zip \
  "$BASE/v1/vault/export"

# Incremental (since)
curl -fSL \
  -H "Authorization: Bearer $TOKEN" \
  -o vault-incremental.zip \
  "$BASE/v1/vault/export?since=2026-05-01T00:00:00Z"

# Verify
unzip -l vault.zip | head -20
```

## Bruno

See `bruno/vault/export-zip.bru`.
