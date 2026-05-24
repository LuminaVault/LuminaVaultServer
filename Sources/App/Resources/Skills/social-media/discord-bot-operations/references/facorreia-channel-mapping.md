# FACorreia Discord Channel Mapping

Discovered from `/opt/data/channel_directory.json` (gateway sync, 2026-05-03).

## Guild
**FACorreia** — Primary guild where Hermes bot operates.

## Channels

| Channel ID | Name | Purpose / Typical Content |
|------------|------|---------------------------|
| `1498025894751768776` | `#hermes` | Home channel — general Hermes digests, agent logs, system updates. Used for `news_digest.py` output. |
| `1499338003334561843` | `#stock-news` | Daily stock market news digest (`daily_stock_news.py`, `daily_stock_news_triple.py`). |
| `1499331939469889656` | `#tv-anime-and-movies` | Combined cinema digest (`daily_cinema_chatter.py` aggregating movies + anime + TV). |
| `1498815493757341896` | `#stock-alerts` | Real-time price threshold alerts (from `stock-alert-orchestrator`). |
| `1498815544898617505` | `#crypto-alerts` | Cryptocurrency price threshold alerts (from `crypto-threshold-monitoring`). |
| `1499908671847661578` | `#swift` | Swift / SwiftUI / iOS development news and updates. |
| `1499908914500862123` | `#golang` | Go language / Golang ecosystem news. |
| `1499349013529493536` | `#slbenfica` | SL Benfica sports news and match updates. |
| `1499349432863555675` | `#spurs` | Tottenham Hotspur (ASSOCIATION FOOTBALL CLUB) news and match updates. |
| `1499349465142657115` | `#nba` | NBA scores, trades, and headlines. |
| `1499362823342653471` | `#server-alerts` | Hermes server resource monitoring (CPU, memory, disk) — 30-min cadence. |
| `1499908620446601307` | `#projects-hermes` | Project-level Hermes development updates, architecture discussions. |
| `1500153958017011905` | `#project-stockplan` | StockPlan fintech project updates, test flights, roadmap items. |
| `1498009007099613285` | `#norviq-alerts` | Third-party integration alerts (Norviq service). |
| `1245136372575244392` | `#general` | General-purpose discussion (non-digest). |

## Threads
Threads appear with `chat_id:thread_id` composite IDs:

| Composite ID | Guild | Channel | Thread Name |
|--------------|-------|---------|-------------|
| `1498030416496558150:1498030416496558150` | FACorreia | #hermes | `hermes` (topic thread inside #hermes) |
| `1499923861393768508:1499923861393768508` | FACorreia | #swift | Thread discussing: `https://x.com/ios_dev_alb/status/2050218951087362088?s=46` |

## Usage
When sending via `send_message` with explicit ID:
```bash
hermes send_message target="discord:1498025894751768776" message="..."
```

When using human-friendly name resolution (requires channel_directory.json present):
```bash
hermes send_message target="discord:#hermes" message="..."
```

The human-friendly form is preferred for maintainability; numeric IDs are useful as fallbacks when the directory is stale or unavailable.

## Maintenance
- Channel directory is refreshed every 5 minutes by the running gateway.
- New channels appear automatically after the next refresh cycle.
- If a channel is missing, confirm the gateway process is running (`ps aux | grep hermes`) and that the bot is a member of the guild with `View Channel` + `Send Messages` permissions on that channel.
