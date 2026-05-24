---
name: stock-watchlist-delivery
version: 1.0
category: stock-trading
tags: [cron, delivery, discord, watchlist, yahoo-finance]
summary: Post a stock watchlist with prices and changes to Discord channels. Handles both automated fetching and direct output when running as a scheduled job with missing credentials.
description: This skill covers the end-to-end process of delivering a stock watchlist to Discord, including price fetching, table formatting, and posting via bot API or fallback system delivery. It is designed for cron jobs that run on a schedule and may have missing credentials.
---
# Trigger Conditions
- When a cron job or script needs to post a stock watchlist to Discord
- When provided with pre-fetched price data in a specific format
- When the task is to deliver a watchlist table to configured Discord channels
- **When delivering the AI Cohort Scoreboard report** (12 Winners + 12 Disrupted tickers with charts and insider data)
- When running as a scheduled job with missing credentials
- Requires Discord bot token (DISCORD_BOT_TOKEN) in environment or .env file
- Optional: yfinance for fetching live prices
- Python 3.10+ with standard library (urllib, json, yaml)

# Procedure

## 1. Determine Data Source
- If price data is **not provided**, fetch live prices using yfinance:
  - Download historical data for the watchlist tickers
  - Extract latest close price and previous close for change calculation
- If price data **is provided** (as in cron job output), use it directly to skip fetching

## 2. Format the Table
- Build a markdown table with header: "# 📋 Will Do Watchlist — {timestamp ET}"
- Columns: Instrument | Last | Change | %
- Include a footer: "_Data powered by Yahoo Finance_"
- Format each row with proper sign (+/-) for changes
- Round prices to 2 decimals, percentages to 2 decimals

## 3. Post to Discord
### A. Ideal Method (Bot Token)
- Load DISCORD_BOT_TOKEN from environment or .env file
- For each configured channel ID, send HTTP POST to:
  `https://discord.com/api/v10/channels/{channel_id}/messages`
- Payload: JSON `{ "content": table }`
- Headers: `Authorization: Bot {token}`, `Content-Type: application/json`
- Handle errors (401, 403, 404, timeout) and log appropriately

### B. Fallback Method (System Delivery)
- If Discord bot token is missing or invalid, simply output the table as final response
- Trust that the Hermes system will automatically deliver the output to the configured destination
- This is the expected behavior for scheduled cron jobs when credentials are not available

## 4. Verification
- Check HTTP response status (200 or 204) for each Discord post
- If using fallback, confirm that the output was generated without errors
- Log success/failure messages to stderr for monitoring

# Pitfalls
- ⚠️ **Missing Token**: The Discord bot token is often stored in `/opt/data/.env` but may be a placeholder. Always check if the token is valid before attempting API calls.
- ⚠️ **Rate Limits**: Discord has strict rate limits. Space out messages if posting to many channels.
- ⚠️ **Channel Permissions**: Ensure the bot is a member of the server and has permission to post in the target channels.
- ⚠️ **Data Freshness**: When fetching prices, use `auto_adjust=True` to account for splits.
- ⚠️ **Cron Environment**: Cron jobs run in a minimal environment; explicitly load .env files if needed.
- ⚠️ **Unicode Variation Selectors**: Discord API and security scanners may block messages containing emoji or variation selector characters (U+FE00-UU+FE0F). When running in automated environments, consider removing emojis from the header to avoid delivery failures.
- ⚠️ **Token Extraction**: If the Discord bot token is not present in the environment, read it directly from `/opt/data/.env` by searching for `export DISCORD_BOT_TOKEN=`. The token may be truncated or masked in the file; verify it's a complete valid token.
- ⚠️ **Path Configuration Mismatch**: Scripts often have hardcoded paths that don't match the actual filesystem layout. Common mismatches:
  - `VAULT_ROOT` pointing to `/opt/data/home/.hermes/obsidian-vault/FACorreia` when the actual vault is at `/opt/data/home/obsidian-vault/FACorreia`
  - Default root paths in `load_config()` and `ArgumentParser` pointing to `/opt/data/home/.hermes/scripts/ai-scoreboard` when the actual location is `/root/.hermes/home/.hermes/scripts/ai-scoreboard`
  - **Fix**: Search for occurrences of `/opt/data/home/.hermes/` and replace with the correct path. Verify by running the script directly before cron deployment.

# Configuration
- Watchlist tickers: loaded from `~/.hermes/scripts/ai-scoreboard/config.yaml` under `watchlist.tickers`
- Discord channel IDs: typically two channels (Stock and home)
- Timezone: America/New_York for timestamps

# References
- Existing script: `~/./skills/watchlist_poster_original.py` (template for bot method)
- Cron job schedule: every 30 minutes during weekdays
- Data source: Yahoo Finance via yfinance library

# Related Skills
- corporate-announcements (for earnings delivery)
- stock-threshold-monitoring (for price alerts)
- script-based-discord-delivery (general Discord posting patterns)