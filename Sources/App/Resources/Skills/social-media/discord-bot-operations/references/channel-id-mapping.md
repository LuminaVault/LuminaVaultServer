# Channel ID Mapping (Discord)

This document records the bot’s delivery targets for StockPlan/Hermes automation.

## Primary Content Channels

| Channel ID | Name (guess) | Content Type | Cron Job(s) |
|------------|--------------|--------------|-------------|
| `1499331939469889656` | #cinema (or #daily-digest) | Daily Cinema Chatter (movies + anime + TV combined) | `daily-cinema-chatter`, multi-scrape digests |
| `1499338003334561843` | #hermes | Stock alerts + daily stock news | `stock-alert-triple`, `daily-stock-news-triple` |
| `1498811072155484330` | #alerts or #server-monitoring | Server resource alerts (30 min) | `hermes-server-resource-alerts`, `prod-server-resource-alerts` |

## Multi-Guild Targets (admin/owner guilds)

| Guild ID | Role | Notes |
|----------|------|-------|
| `1498988528745451671` | Guild A (origin/primary) | Bot has admin; general notifications |
| `1498988480938643527` | Guild B | Secondary server; needs explicit deliver target |
| `1498025894751768776` | Guild C | Weekly learning digest destination (`weekly-learning-digest`) |

## Usage in Jobs

Example cron job deliver values:
- `deliver: discord:1499331939469889656` → cinema channel
- `deliver: discord:1499338003334561843` → hermes channel
- `deliver: discord:1498811072155484330` → alerts channel
- `deliver: discord` → default home channel (if configured)
- `deliver: origin` → message back to Hermes host via origin platform

## Maintenance
When adding a new channel:
1. Invite bot to the guild and grant View + Send in that channel.
2. Record the channel ID here.
3. Update any jobs that should target it.
4. Test with a diagnostic message via `send_message`.
