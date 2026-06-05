# APNS (Push Notifications) Setup — LuminaVault

How push works end-to-end and exactly what to do to enable it in production
(TestFlight builds included). App: `com.lumina.fernando`, Team `84X9WYBF36`.

## How it works
1. iOS app registers for remote notifications → gets an **APNs device token** →
   `POST /v1/devices` (JWT-authed) stores it (`DeviceToken` model).
2. Server sends pushes via `APNSNotificationService` → `APNSClient`, authenticated
   with an **APNs Auth Key (.p8)** + Key ID + Team ID, topic = bundle id.
3. `DELETE /v1/devices/:token` unregisters (e.g. on logout).

**Key facts**
- The `.p8` is read from a **file** on the server (`/app/secrets/apns-key.p8`),
  mounted read-only from `./secrets/` on the VPS. It is **not** an env var.
- APNs Auth Keys are **team-wide** — one key works for every app in team
  `84X9WYBF36`. The app is selected by the **topic** (= bundle id).
- **TestFlight and the App Store both use the `production` APNs environment.**
  Only direct Xcode debug builds use `sandbox`. Release entitlements already set
  `aps-environment = production`, so `APNS_ENVIRONMENT=production` is correct.
- Fail-soft: if `APNS_ENABLED=true` but the `.p8` is missing/invalid, the push
  sender stays nil and notifications no-op — the app does **not** crash.

## Server config (already wired)
`docker-compose.production.yml` bakes the public/stable values as defaults:

| Setting | Default (baked) | Override in `.env.production` (host var) |
| --- | --- | --- |
| `APNS_BUNDLE_ID` (topic) | `com.lumina.fernando` | `APNS_BUNDLEID` |
| `APNS_TEAM_ID` | `84X9WYBF36` | `APNS_TEAMID` |
| `APNS_ENVIRONMENT` | `production` | `APNS_ENVIRONMENT` |
| `APNS_PRIVATE_KEY_PATH` | `/app/secrets/apns-key.p8` | `APNS_PRIVATEKEYPATH` |
| `APNS_ENABLED` | `false` (gate) | `APNS_ENABLED` |
| `APNS_KEY_ID` | empty | `APNS_KEYID` |

So to go live you only provide the **`.p8` file**, `APNS_ENABLED=true`, and
`APNS_KEYID`.

## Steps to enable push in production

### 1. Apple — App ID capability (one-time)
developer.apple.com → Certificates, IDs & Profiles → **Identifiers** →
`com.lumina.fernando` → ensure **Push Notifications** is enabled. (Release
entitlements already declare `aps-environment: production`.)

### 2. Apple — create the APNs Auth Key (one-time, team-wide)
Keys → **＋** → check **Apple Push Notifications service (APNs)** → Register →
**Download** `AuthKey_XXXXXXXXXX.p8` (one-time download). The `XXXXXXXXXX` is the
**Key ID**. Keep the file safe (1Password).
> If reusing an existing key, its `.p8` is downloadable only once — if you lost
> it, revoke and create a new one.

### 3. VPS — drop the key file
```bash
scp -i /tmp/lv_deploy AuthKey_XXXXXXXXXX.p8 \
  root@167.233.30.48:/opt/obsidian-claudebrain/secrets/apns-key.p8
```
`secrets/` is gitignored and mounted read-only into the app at `/app/secrets`, so
it survives deploys.

### 4. VPS — set the two remaining vars
Append to `/opt/obsidian-claudebrain/.env.production`:
```
APNS_ENABLED=true
APNS_KEYID=XXXXXXXXXX
```
(`APNS_BUNDLEID` / `APNS_TEAMID` / `APNS_ENVIRONMENT` come from the baked
defaults — only set them here to override.)

### 5. Recreate the app container
Either redeploy from CI (`gh workflow run prod.yml`) or on the VPS:
```bash
cd /opt/obsidian-claudebrain
docker compose -p prod -f docker-compose.production.yml --env-file .env.production up -d --no-deps app
docker compose -p prod logs --tail=50 app | grep -i apns   # expect no "APNS client init failed"
```

## Verify
1. Install a **TestFlight** build on a real device (push needs a physical device),
   grant the notification prompt.
2. App registers → confirm a row landed: it called `POST /v1/devices`.
3. Trigger a push from whatever server flow sends one; the device should receive it.
4. If nothing arrives, check `docker compose logs app | grep -i apns` for
   `BadDeviceToken` (wrong environment), `InvalidProviderToken` (key/team/key-id
   mismatch), or `TopicDisallowed` (bundle id ≠ topic).

## Common errors
- **`BadDeviceToken`** — token registered on a different APNs env. TestFlight =
  `production`; make sure `APNS_ENVIRONMENT=production`.
- **`InvalidProviderToken` / 403** — `APNS_KEYID` doesn't match the `.p8`, or wrong
  `APNS_TEAMID`. The Key ID must equal the `AuthKey_XXXX.p8` suffix.
- **`TopicDisallowed`** — `APNS_BUNDLE_ID` must equal the app bundle id.
- **No-op, no error** — `APNS_ENABLED` not `true`, or `.p8` not at the mounted path.

## Production (App Store) vs TestFlight
No difference for APNs — both are the **production** environment and use the same
key + topic. Nothing extra to change between TestFlight and public release.
