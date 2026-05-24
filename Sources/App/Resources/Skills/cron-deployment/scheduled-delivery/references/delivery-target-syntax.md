# Cron Job Delivery Targets — Quick Reference

## Syntax

| Value | Meaning |
|-------|---------|
| `origin` | Back to Hermes host (cron stdout → agent receives as output) |
| `discord` | Default Discord home channel (if bot configured one) |
| `discord:CHANNEL_ID` | Specific Discord channel by numeric ID |
| `telegram` | Default Telegram chat (bot's configured chat) |
| `telegram:CHAT_ID` | Specific Telegram chat by ID |
| `slack` | Default Slack channel |
| `email` | Email (script must implement SMTP itself; cron framework doesn't handle) |

## Decision Tree

```
Need to deliver cron job output?
  ├─ Yes, to a platform
  │   ├─ Single fixed channel? → Use discord:CHANNEL_ID (or telegram/slack)
  │   ├─ Multiple channels based on content? → Use Pathway B (explicit send in script)
  │   └─ Just want to see output in logs? → Use origin
  └─ Need conditional/dynamic routing? → Use Pathway B (script handles delivery)
```

## Examples

**Weekly learning digest to specific Discord channel:**
```json
{
  "name": "weekly-learning-digest",
  "script": ".../digest.py",
  "deliver": "discord:1498025894751768776"
}
```

**Daily stock news to default Hermes host (for debugging):**
```json
{
  "name": "daily-stock-news",
  "script": ".../news.py",
  "deliver": "origin"
}
```

**Real-time alerts that go to multiple places:**
```json
{
  "name": "stock-threshold-alert",
  "script": ".../alert.py",
  "deliver": "origin"  // Script itself posts to Discord + Telegram via webhooks
}
```

## Gotchas

- `origin` does NOT mean "post to Discord home" — it means "return to Hermes"
- `discord` (no ID) uses whatever is configured as the bot's default home channel; may be unset
- Always use `discord:CHANNEL_ID` for explicit, reliable targeting
- Cron framework respects `deliver` at submission time — changing the job's `deliver` affects future runs only

## Channel ID Mapping

See `discord-bot-operations` skill → `references/channel-id-mapping.md` for current IDs.

Quick lookup (as of 2026-05):
- `1499331939469889656` — #cinema / daily-digest (movies, anime, TV)
- `1499338003334561843` — #hermes (stock alerts, stock news)
- `1499908671847661578` — Swift/iOS news channel
- `1499908914500862123` — Golang news channel
- `1498811072155484330` — Server monitoring alerts
- `1498025894751768776` — Weekly learning digest (Guild C)
