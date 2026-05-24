# Self-delivering cron alerts

Use this pattern when the script itself posts to Discord/Telegram/Slack instead of relying on Hermes cron delivery.

## When to use
- The script already has the bot token / webhook and directly sends the alert.
- The job exits with code `1` to signal "alert found" rather than failure.
- The Hermes cron `deliver` target is causing a double-send or a false delivery failure.

## Contract
- Cron job should use `deliver: origin` or `deliver: local` so Hermes captures logs but does not attempt a second platform post.
- The wrapper should treat exit code `1` as success only when the script emitted a valid alert payload.
- Transport failures must still surface as non-zero exits.

## Discord-specific requirements
- Include `User-Agent: HermesBot/1.0` on Python `urllib`/`requests` calls when Discord returns `403` despite valid token and channel access.
- Verify the token first with `GET /users/@me`.
- Verify channel access with `GET /channels/<id>` before debugging permissions.

## Common failure modes
- `deliver: discord:<channel>` on a self-delivering script causes duplicate delivery or confusing failures.
- A valid alert script exits `1` and gets treated as a cron failure by the wrapper.
- Discord `403` is often a transport/WAF issue, not a bot membership problem.

## Quick checks
1. Run the wrapped detector directly and confirm it prints the alert text.
2. Confirm `GET /users/@me` returns `200` with the bot token.
3. Confirm the target channel returns `200` for `GET /channels/<id>`.
4. Set cron delivery to `origin`/`local` when the script self-posts.

## Session note
This pattern was used for `ai-cohort-alerts-hourly` after the bot token and channel were valid, but direct Discord posting still failed with `HTTP 403`. The fix was to let the wrapper send directly and set the cron job delivery to local/origin so Hermes did not try to deliver a second time.