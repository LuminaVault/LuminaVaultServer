---
name: corporate-announcements
description: Weekly calendar combining upcoming earnings dates and SEC corporate announcements (8-K, Form 4) for a watchlist of tickers. Orchestrates data fetching, filtering, formatting, and multi-channel delivery (Discord + Obsidian vault).
triggers:
  - "weekly earnings calendar"
  - "corporate announcements calendar"
  - "earnings and SEC filings calendar"
  - "upcoming earnings dates for my watchlist"
  - "8-K and Form 4 announcements"
critical-path:
  - "Define watchlist tickers"
  - "Fetch SEC EDGAR RSS (last 7 days)"
  - "Filter for 8-K / Form 4 matching watchlist (strict ticker-in-parentheses pattern)"
  - "Optional: fetch earnings calendar from Finnhub if API key available"
  - "Format output (Discord message + markdown)"
  - "Post to Discord channel"
  - "Write to Obsidian vault"
  - "Exit 0 on success; exit 1 only on misconfiguration (missing token)"
failure-modes:
  - Missing DISCORD_BOT_TOKEN: exits 1 immediately
  - SEC filter CIK false-positives: solved by requiring `(TICKER)` pattern not substring
  - No free earnings API: Yahoo Finance fails (JS-rendered), Finnhub requires key; degrade gracefully with placeholder
  - Discord 403: bot not in guild or missing View/Send perms on target channel
tooling:
  - python3 with feedparser (RSS), requests
  - Cron for weekly scheduling (Sunday 9AM recommended)
  - Discord webhook/bot token for posting
outputs:
  - Discord message (rich embed or markdown)
  - Markdown file: Raw/HermesPortfolio/Earnings/calendar_YYYYMMDD.md
user-preferences:
  verbosity: "quiet unless errors or relevant findings"
  empty-output: "no 'no news' spam — post only when at least one section has content"
  schedule: "weekly (Sundays 9AM), not daily"
  delivery: "local cron deliver, not multi-target broadcast"
  vault-root: "/opt/data/obsidian-vault"
references:
  - references/watchlist-format.md
  - references/sec-edgar-filtering.md
  - references/discord-post-format.md
templates:
  - templates/earnings_announcements.py
---

## Overview

This skill governs the end-to-end weekly production of an earnings & corporate announcements calendar for a personal investment watchlist. It combines **SEC EDGAR filings** (8-K material news, Form 4 insider trades) with **upcoming earnings dates** into a single report posted to Discord and saved to the Obsidian vault for historical tracking.

## Trigger Conditions

Use this skill when the user requests:
- A weekly calendar of upcoming earnings dates for their watchlist
- A digest of recent SEC announcements (8-K, Form 4) for their holdings
- Combined earnings + announcements report (preferred unified view)
- Any mention of "calendar" + "earnings" + "watchlist" or "SEC filings"

## Critical Path (Step-by-Step)

1. **Load configuration**
   - Read `.env` for `DISCORD_BOT_TOKEN` (required) and `FINNHUB_API_KEY` (optional)
   - Define watchlist tickers (hardcoded array matching stock-alert scripts)
   - Resolve vault root from memory or default `/opt/data/obsidian-vault`

2. **Fetch SEC EDGAR RSS**
   - Endpoint: `https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&count=200&output=atom`
   - Parse with `feedparser` or XML parser
   - Cutoff: last 7 days (rolling window)
   - Extract: title, link, published date, CIK/ticker from title field

3. **Filter for relevant filings**
   - Accept only form types: `8-K` and `Form 4` (expandable)
   - Match tickers against watchlist using **strict pattern**: ticker must appear inside parentheses in title, e.g., `8-K — Company (ZETA)`
   - Regex: `r'\((?:ZETA|AMD|AMZN|...)\)'` (non-capturing group, exact match)
   - Extract ticker by slicing `match.group(0)[1:-1]`
   - **Pitfall**: Substring matches (CIK numbers like `110698`) are false positives; never match bare ticker substrings outside parens

4. **Fetch upcoming earnings (optional)**
   - If `FINNHUB_API_KEY` present: call `GET https://finnhub.io/api/v1/calendar/earnings?from=...&to=...&token=...`
   - Parse response JSON; filter to watchlist tickers with announced dates
   - If no key: set earnings_section = None (graceful degradation)
   - **Pitfall**: Yahoo Finance earnings calendar is JavaScript-rendered; static HTML fetch returns no data. Do not rely on it.

5. **Format output**
   - Discord: Rich embed or markdown blocks with sections for SEC filings (grouped by form type) and earnings (sorted by date)
   - Vault: Markdown file with frontmatter-like header, same content as Discord
   - **Rule**: If both SEC and earnings sections are empty, exit 0 silently (no output anywhere)

6. **Deliver**
   - Post to Discord channel using bot token (channel ID: 1499338003334561843 for StockPlan)
   - Write markdown to vault: `{vault_root}/Raw/HermesPortfolio/Earnings/calendar_YYYYMMDD.md`
   - Create parent directories if needed

7. **Exit codes**
   - `0`: success (with or without content posted)
   - `1`: misconfiguration (missing `DISCORD_BOT_TOKEN`)

## Pitfalls & Gotchas

- **SEC title parsing**: SEC RSS titles are like `8-K — Company Name (CIK0001234567)` or `8-K — Company (TICKER)`. Your filter must distinguish CIK numbers (all digits, 10 digits) from tickers (1–5 letters). The safest approach: require the ticker to be inside parentheses AND match exactly a watchlist symbol. Do not use substring matching on the entire title string.
- **Timezone handling**: Use `datetime.now(datetime.UTC)` (not deprecated `utcnow()`). The RSS dates are typically EST/EDT; convert to UTC or keep naive consistently.
- **Duplicate filings**: SEC may publish the same filing multiple times (e.g., amendment). Deduplicate by `link` or `title` if needed.
- **Finnhub rate limits**: Free tier: 60 calls/minute. Cache weekly results; do not poll daily.
- **Discord permissions**: Bot must be a **member of the guild** containing the target channel and have both `View Channel` and `Send Messages` permissions. A 403 error means the bot is not in the server or lacks access.
- **Vault path**: Use memory-stored vault root; default `/opt/data/obsidian-vault`. The older path `/opt/obsidian-vault` is deprecated.

## Reference Implementation

See `templates/earnings_announcements.py` for a complete, working script (~150 lines) that implements this skill. It includes:
- `.env` loading
- SEC RSS fetch + parse
- Watchlist filtering with strict parens pattern
- Optional Finnhub earnings fetch
- Discord posting (presence-aware retry)
- Vault markdown write with date-stamped filename
- Quiet stderr-only logging (except stdout for cron deliver)

## Related Skills

- `stock-trading`: Portfolio tracking and price threshold alerts (hourly)
- `stockplan-dev-standards`: Weekly review cadence and vault conventions
- `knowledge-base`: Archive all Q&A and decisions in Obsidian

## Future Extensions

- Add RSS from Seeking Alpha (ticker-filtered) for analyst commentary
- Include Form 10-Q/10-K periodic reports (lower frequency)
- Push notifications for critical 8-K items (Item 1.01, 2.01, 5.02) via Telegram/Slack
- Integrate with `portfolio-tracker` to weight announcements by position size
