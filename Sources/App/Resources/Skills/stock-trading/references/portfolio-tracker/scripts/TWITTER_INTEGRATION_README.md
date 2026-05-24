# Hermes Twitter/X Integration

Two automation systems:

1. **Tweet Monitor** — Daily digest of tweets matching your interests from @fatc88, their following list, and keyword search.
2. **StockPlan Promotion** — Hourly auto-posted tweets to @fatc88 promoting the StockPlan app.

---

## 📦 Files

```
~/.hermes/scripts/
├── tweet_monitor.py                # Daily digest fetcher
├── stockplan_promotion.py          # Hourly poster (24 unique messages)
├── stockplan_promotion_daemon.py   # Daemon wrapper (optional)
└── TWITTER_INTEGRATION_README.md   # This file
```

Output:
```
~/.hermes/output/
├── tweet_digest_YYYY-MM-DD.md      # Daily resume
└── stockplan_tweets/               # Archive of published promos
    ├── 2026-04-27_0900.md
    └── …
```

---

## 🔐 Credentials

Store your X API credentials in **memory** via Hermes:

```bash
# In chat, say: "store TWITTER_BEARER_TOKEN=YOUR_BEARER_TOKEN"
# I'll persist it across sessions
```

Alternative: export as environment variables in the cron job environment:

```bash
export TWITTER_BEARER_TOKEN="YOUR_BEARER_TOKEN"
export TWITTER_ACCESS_TOKEN="YOUR_ACCESS_TOKEN"
```

**Token scopes required:**
- Bearer token (App-only): `tweet.read` (for fetching/searching)
- Access token (OAuth2 user): `tweet.write` (for posting promos)

---

## 🐦 Tweet Monitor (Daily Digest)

**What it does:**
1. Resolves `@fatc88` to user ID
2. Fetches their tweets from last 2 days
3. Gets list of accounts they follow (samples first 30)
4. Fetches tweets from those accounts
5. Searches recent tweets for each topic keyword
6. Filters all tweets by topic keywords (stocks, nba, sl benfica, tech, ai, swift, ios, golang)
7. Deduplicates, ranks by engagement (likes + 2×retweets + replies), formats Markdown

**Output:** `~/.hermes/output/tweet_digest_YYYY-MM-DD.md`

**Cron job (3 platforms):**

| Platform | Job ID (example) | Schedule |
|----------|------------------|----------|
| Discord  | `tweet_digest_discord` | Daily 08:00 UTC |
| Telegram | `tweet_digest_telegram`| Daily 08:00 UTC |
| Slack    | `tweet_digest_slack`   | Daily 08:00 UTC |

**Deliverables:** Markdown file + posted to Discord origin/Telegram home/Slack default

---

## 📢 StockPlan Promotion (Hourly Posts)

**What it does:**
- Publishes 1 of 24 unique pre-written messages per hour (UTC hour-based rotation)
- Auto-posts to @fatc88 account using OAuth2 user access token
- Archives each published tweet with timestamp + link

**Posting schedule:**
- Hourly at :00 UTC (24 tweets/day)
- 24 unique messages rotate daily; same hour posts same message each day
- Covers: features, tips, market insights, fintech education, Norviq branding

**Hashtags:** `#StockPlan #iOS #SwiftUI #FinTech #Investing #Norviq`

**Cron job (3 platforms for digest only; posting is direct to X):**

| Delivery | Job ID | Schedule |
|----------|--------|----------|
| Markdown → file | `stockplan_promo_md` | Hourly :00 UTC |
| Discord origin  | `stockplan_promo_discord` | Hourly :05 UTC (5min lag to confirm post) |
| Telegram home  | `stockplan_promo_telegram`| Hourly :05 UTC |
| Slack default  | `stockplan_promo_slack`   | Hourly :05 UTC |

**Daemon mode (optional):** Run `stockplan_promotion_daemon.py start` to keep a persistent process that publishes exactly on the hour. Useful if cron is unreliable.

---

## ⚙️ Setup Commands (run once on VPS)

```bash
# Make scripts executable
chmod +x ~/.hermes/scripts/tweet_monitor.py
chmod +x ~/.hermes/scripts/stockplan_promotion.py
chmod +x ~/.hermes/scripts/stockplan_promotion_daemon.py

# Test tweet monitor
~/.hermes/scripts/tweet_monitor.py

# Test single promotion
~/.hermes/scripts/stockplan_promotion.py
```

**Create cron jobs:** (I'll generate these)

- Daily digest (08:00 UTC): `tweet_monitor.py` → deliver to Discord + Telegram + Slack
- Hourly promo (:00 UTC): `stockplan_promotion_daemon.py runonce` → publish + deliver summary to platforms

To switch to daemon mode instead of cron per-hour:

```bash
# Start persistent daemon
~/.hermes/scripts/stockplan_promotion_daemon.py start

# Enable at boot (systemd): see systemd/stockplan-promo.service
```

---

## 📊 Daily Digest Example Output

```
# 📊 Hermes Tweet Digest — Monday, Apr 27, 2026
_Monitoring @fatc88 + following list — topics: stocks, nba, sl benfica, tech, ai, swift, ios, golang_

**34 tweet(s)** matched your interests today.

## 📍 @fatc88 (own)
- **@fatc88** · 2026-04-27 ❤️ 45 🔄 12
  > SwiftUI performance tip: Use @State for local UI state, @Observed for shared…
  [View tweet →](https://twitter.com/i/status/…)

## 📍 Following accounts
- **@swiftnews** · 2026-04-27 ❤️ 234 🔄 56
  > Apple announces Swift 6 with full concurrency safety…
  [View tweet →](https://twitter.com/i/status/…)

## 📍 Keyword search
- **@nba** · 2026-04-27 ❤️ 1201 🔄 403
  > Playoff schedule announced…
  [View tweet →](https://twitter.com/i/status/…)
```

---

## 🎯 Topics Filtered (case-insensitive)

| Topic | Keywords matched |
|-------|------------------|
| Stocks | `stock`, `stocks`, `portfolio`, `invest`, `market`, `trading`, `nasdaq`, `nyse` |
| NBA | `nba`, `basketball`, `playoff`, `lakers`, `warriors`, `celtics`, `nets`, `heat` |
| SL Benfica | `sl benfica`, `benfica`, `sporting`, `lisboa` (case-insensitive) |
| Tech | `tech`, `technology`, `startup`, `silicon valley`, `ai`, `ml` |
| AI | `ai`, `artificial intelligence`, `llm`, `gpt`, `machine learning`, `deep learning` |
| Swift | `swift`, `swiftui`, `ios dev`, `apple`, `xcode`, `swiftlang` |
| iOS | `ios`, `iphone`, `ipad`, `app store`, `mobile` |
| Go | `golang`, `go lang`, `gopher`, `vapor` |

---

## 🛠️ Troubleshooting

**401 Unauthorized on fetch:** Bearer token needs `tweet.read` scope. Regenerate on Twitter Dev Portal.

**403 Forbidden on post:** Access token needs `tweet.write` scope. Use OAuth2 user flow with correct scopes.

**Rate-limit exceeded (`429`):** Monitor `x-rate-limit-remaining` headers; backoffs implemented (1s between following fetch). Reduce sample size if needed.

**Empty digest:** No matching tweets in last 2 days. Expand `TOPICS` list or increase `days_back` in `tweet_monitor.py`.

**Daemon not starting:** Check `/tmp/stockplan_promo.log` for HTTP errors. Ensure token hasn't expired.

---

## 🔗 Parameters to tweak

| Parameter | Location | Description | Default |
|-----------|----------|-------------|---------|
| `TOPICS` | `tweet_monitor.py` | Keywords to match | 8 topics |
| `TARGET_USERNAME` | `tweet_monitor.py` | User to monitor | `fatc88` |
| `PAGE_SIZE` | `tweet_monitor.py` | Tweets per request | 100 |
| `SAMPLE_SIZE` | `tweet_monitor.py` | Number of followed users to scan | 30 |
| `TWEET_POOL` | `stockplan_promotion.py` | 24 hourly messages | See file |
| `OUTPUT_DIR` | both | Where Markdown saved | `~/.hermes/output/` |

---

## 📁 Example cron entries (UTC)

```cron
# ── Tweet Monitor — Daily digest at 08:00 ─────────────────────────────────────
0 8 * * * /opt/data/home/.hermes/scripts/tweet_monitor.py 2>&1 | /opt/data/home/.hermes/scripts/deliver_to_discord.sh "#hermes"
0 8 * * * /opt/data/home/.hermes/scripts/tweet_monitor.py 2>&1 | /opt/data/home/.hermes/scripts/deliver_to_telegram.sh "HermesBot"
0 8 * * * /opt/data/home/.hermes/scripts/tweet_monitor.py 2>&1 | /opt/data/home/.hermes/scripts/deliver_to_slack.sh "#hermes-alerts"

# ── StockPlan Promotion — Hourly tweet at :00 ─────────────────────────────────
0 * * * * /opt/data/home/.hermes/scripts/stockplan_promotion_daemon.py runonce >> /tmp/stockplan_promo_cron.log 2>&1
```

**Note:** Hermes cron system uses `cronjob` tool with job IDs, not crontab directly. Use `cronjob create` with schedule `0 8 * * *` for digest, `0 * * * *` for promo.

---

## 🚀 Next-phase ideas

- **Notify on viral tweets** (score > 10k) with instant DM
- **Weekly summary PDF** → Notion DB via Notion API skill
- **Sentiment analysis** per ticker (AMD, GOOGL, etc.)
- **NLP extraction** of key entities (people, companies, products)
- **Auto-retweet** accounts whose content is consistently high-value
- **Competitor tracking** for StockPlan mentions

All set! Tweet Monitor and StockPlan Promotion are production-ready after you provide tokens.
