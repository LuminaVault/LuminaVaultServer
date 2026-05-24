# Content Scripts Inventory

Scripts that produce content for Discord digests, their locations, outputs, and schedules.

## Core Aggregators

| Script | Path | Output | Notes |
|--------|------|--------|-------|
| **daily_cinema_chatter.py** | `~/.hermes/scripts/daily_cinema_chatter.py` | `~/movie_digest_today.md` + log entry | Theatrical top 10 grossing films + Reddit/Google News buzz. Runs daily at 09:00 via cron (`daily-cinema-chatter`). |
| **mal_seasonal_scraper.py** | `~/.hermes/scripts/mal_seasonal_scraper.py` | `~/obsidian-vault/FACorreia/Raw/Anime/Seasonal/<season> Seasonal Anime & Movies.md` | Scrapes MyAnimeList seasonal anime (~165 series) + top movies via Jikan. Runs monthly on 1st at 09:00 (`mal-seasonal-scraper-monthly`). |
| **tvshows_seasonal_scraper.py** | `~/.hermes/scripts/tvshows_seasonal_scraper.py` | `~/obsidian-vault/FACorreia/Raw/TV/Seasonal/<season> TV Shows.md` | TVmaze schedule aggregation (all shows airing this season, ~53 series). Runs monthly on 1st at 10:00 (`tvshows-seasonal-scraper-monthly`). |
| **news_digest.py** | `~/.hermes/scripts/news_digest.py` | Markdown to stdout (captured by job) | General tech/news headlines (Hacker News, TechCrunch, Ars, The Verge). Runs twice daily (`twice-daily-news-digest`). |
| **daily_stock_news.py** | `~/.hermes/scripts/daily_stock_news.py` | Markdown to stdout | Yahoo Finance + Google News RSS for followed tickers. Runs daily (`daily-stock-news`). |

## Multi-Target Publishers

| Script | Purpose | Targets |
|--------|---------|---------|
| `stock_news_triple.py` | Posts daily stock news to Discord+Telegram+Slack | `1499338003334561843` (Discord) |
| `stock_alert_triple.py` | Hourly stock threshold alerts to all platforms | `1499338003334561843` (Discord) |
| `daily_cinema_chatter.py` | Posts movie digest to Discord (channel: `1499331939469889656`) | Origin/Discord only |

## How to Add a New Scraper
1. Write script to write a **complete Markdown digest** to a known file path or stdout.
2. Create a cron job with `deliver` set appropriately.
3. If the output is >2000 chars, plan to send as file attachment (see publishing procedure).
4. Document the scraper in this inventory.

## Output Format Conventions
- Title: `# <Category> — <YYYY-MM-DD>`
- Sections: `## <Heading>` with bullet points or tables
- Source attribution at bottom: `*Sources: …*`
- Keep tables narrow (≤5 columns) for Discord readability
