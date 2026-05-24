# Self-delivering cron job Discord 403 case

Session note:
- `ai-cohort-alerts-hourly` was failing with `HTTP 403: Forbidden` even though:
  - `GET /users/@me` with the bot token returned 200
  - `GET /channels/1498815493757341896` returned 200
- The failure was in the delivery path, not guild membership.

Fix pattern:
- If the alert script itself posts to Discord, set the cron job `deliver` to `origin` or `local` so Hermes does not attempt a second Discord post.
- Preserve the script's intentional `exit 1` only when it means "alert found" and the payload was actually generated.
- For Python Discord requests, always include:
  - `Authorization: Bot <token>`
  - `Content-Type: application/json`
  - `User-Agent: HermesBot/1.0`

Verification:
1. Validate token with `/users/@me`.
2. Validate channel with `/channels/<id>`.
3. Confirm the script emits the expected alert text before changing cron delivery.
4. Update the cron target before chasing permissions if the script is self-delivering.