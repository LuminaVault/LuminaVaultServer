# Discord Channel Mapping — Cron Delivery Targets

**Source:** `discord-bot-operations` skill's `channel-id-mapping.md`  
**Scope:** Guilds where Hermes/StockPlan bot is a member  
**Updated:** 2026-05-02 (from session discovery)

## Guild Membership Required

For `deliver: discord:CHANNEL_ID` to work, the bot **MUST** be a member of the guild containing that channel. The bot's role must have:
- **View Channel** allowed (no channel override denies)
- **Send Messages** allowed
- Role hierarchy high enough to override restrictive roles

Check membership: `hermes cron status` → last_delivery_error (403 = membership issue)

## Primary Content Channels

| Channel ID | Guild | # | Purpose | Cron Jobs Using It |
|------------|-------|---|---------|-------------------|
| `1499331939469889656` | Guild A | #cinema-or-daily-digest | Movies + Anime + TV combined digests | `daily-cinema-chatter`, `daily-entertainment-digest`, `weekly-imdb-digest`, `mal-seasonal-scraper-monthly`, `tvshows-seasonal-scraper-monthly` |
| `1499338003334561843` | Guild A | #hermes | Stock alerts + daily stock news | `stock-alert-triple`, `daily-stock-news-triple`, `stock-market-daily-digest` |
| `1499908671847661578` | Guild B | Swift/iOS news | Swift/iOS development news | `daily-swift-news` |
| `1499908914500862123` | Guild B | #golang | Golang news | `daily-go-news` |
| `1498811072155484330` | Guild A | #alerts-or-monitoring | Server resource monitoring alerts (30-min interval) | `hermes-server-resource-alerts`, `prod-server-resource-alerts`, `server-resource-monitor-discord` |

## Multi-Guild Targets (Admin/Owner Guilds)

These guilds contain the agent itself or owner-only content:

| Guild ID | Name | Notes |
|----------|------|-------|
| `1498988528745451671` | Guild A (origin/primary) | Bot has admin; general notifications |
| `1498988480938643527` | Guild B | Secondary server; needs explicit deliver target |
| `1498025894751768776` | Guild C | Weekly learning digest destination only |

## Usage Examples

**Send to stock alerts channel:**
```json
{
  "name": "stock-alert",
  "script": "alert.py",
  "deliver": "discord:1499338003334561843"
}
```

**Send to Swift news channel:**
```json
{
  "name": "swift-news",
  "script": "swift_news.py",
  "deliver": "discord:1499908671847661578"
}
```

**Send to weekly learning digest (Guild C):**
```json
{
  "name": "weekly-learning-digest",
  "script": "learning_digest.py",
  "deliver": "discord:1498025894751768776"
}
```

## Setting Up a New Channel

1. **Invite bot** to the guild via OAuth2 URL (`bot` scope + `Send Messages` + `View Channel` permissions)
2. **Verify role permissions** in the target channel (no explicit denies for View/Send)
3. **Get channel ID:** Enable Developer Mode in Discord → right-click channel → Copy ID
4. **Update `channel-id-mapping.md`** (in `discord-bot-operations` skill) with the new entry
5. **Test:** `hermes cron run TEST_JOB` or use `send_message` manually
6. **Wait ~10 seconds** after invite for Discord to propagate permissions

## Notes on Specific IDs

- **`1498025894751768776` (weekly-learning-digest):** Guild C, NOT the main Hermes guild. This is where the `weekly-learning-digest` cron job posts. Do not repurpose for daily news without changing the job's `deliver` field.
- **`1499331939469889656` (cinema):** The hub for entertainment content; multiple independent scrapers (movies, anime, TV) all route here.
- **`1499908671847661578` + `1499908914500862123`:** Guild B technical channels; separate guild from Guild A (main).

## Troubleshooting 403 Errors

If a cron job delivers with error `403: bot lacks access`:

1. Confirm bot is in the **guild** (visible in member list)
2. Check bot role has **View Channel** + **Send Messages** in that specific channel (channel-level overrides can block even if server-wide allows)
3. Verify no **deny override** sits above bot's role in hierarchy
4. Re-invite bot if needed (OAuth2 with proper scopes)
5. Wait 10 seconds after invite for propagation

Detailed troubleshooting: See `discord-bot-operations` skill → `references/discord-permission-troubleshooting.md`
