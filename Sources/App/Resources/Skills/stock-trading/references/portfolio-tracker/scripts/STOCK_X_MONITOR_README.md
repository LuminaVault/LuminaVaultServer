# Stock Ticker X Monitor — Setup & Usage

## Overview

The script `follow_tickers.py` automatically discovers **Twitter/X accounts** that post about your tracked stock tickers and can follow them for you.

**Tracked tickers (20 total):**
```
ZETA  AMD  AMZN  HIMS  OSCR  SOFI  KRKNF  ONDS
ABCL  GRAB  ASTS  TE   UBER  NFLX  NVO   NKE
SIDU  SMR  FLNC  RDW
```

Special focus accounts you asked about:
- `@EchoAnalysis`
- `@mind1nvestor`
- `@JoannisOrlandos`

---

## Current Status

- ✓ `xurl` installed on host at `/opt/data/home/.local/bin/xurl`
- ✓ Authenticated as `@fatc88` via `x-hermes` app
- ✗ **X API credits DEPLETED** — all search/timeline calls blocked until credits are added

---

## Usage

### Option 1 — Quick combined search (manual)
```bash
# Search all tickers at once
xurl search "$ZETA OR $AMD OR $AMZN OR $SMR OR $FLNC OR $RDW -filter:retweets" -n 50
```

Or use the wrapper script:
```bash
~/.hermes/scripts/x_stock_search.sh search 50
```

### Option 2 — Digest: recent tweets per ticker
Shows latest tweets for each ticker with author info (good for manually finding accounts to follow):
```bash
python3 ~/.hermes/scripts/follow_tickers.py --digest --max-tweets 5
```

### Option 3 — Get follow suggestions
Ranks accounts by follower count + verification, suggests who to follow:
```bash
python3 ~/.hermes/scripts/follow_tickers.py
```
Output format:
```
✓ @StockGuru    Verified Analyst (12,456 followers)  [AMD]
○ @trader_joe   Active Swing Trader (3,210 followers) [SMR]
```
Only shows accounts with ≥1,000 followers by default.

### Option 4 — Auto-follow (execute)
Actually follows the suggested accounts (use cautiously):
```bash
python3 ~/.hermes/scripts/follow_tickers.py --execute
```
This calls `xurl follow <username>` for each suggested account.

### Option 5 — Custom query builder
Prints a copy-paste search string for all tickers:
```bash
python3 ~/.hermes/scripts/follow_tickers.py --query
# → xurl search "$ZETA OR $AMD OR ... -filter:retweets" -n 50
```

---

## Targeted User Queries

Once credits are restored, you can look up specific users directly:

```bash
# Verify they're on X and get their user ID
xurl user EchoAnalysis
xurl user mind1nvestor
xurl user JoannisOrlandos

# Get their recent tweets
xurl user EchoAnalysis --timeline -n 10
xurl search "from:EchoAnalysis $AMD" -n 10
```

---

## Top-up X API Credits

To restore functionality:

1. Go to https://developer.x.com/en/portal/dashboard
2. Navigate to **Billing** → Add credits (minimum ~$5)
3. Wait ~1 minute, then re-run any `xurl` command

After credits restore, all script features will work.

---

## Files

| File | Purpose |
|------|---------|
| `~/.hermes/scripts/stock_threshold_alert.py` | Hourly stock price check (Yahoo Finance) — sends alerts if any ticker ≤ threshold |
| `~/.hermes/scripts/follow_tickers.py` | X account discovery & follow assistant (this script) |
| `~/.hermes/scripts/x_stock_search.sh` | Bash wrapper for one-liner searches |
| `~/.xurl` | OAuth tokens (auto-loaded by xurl) |

---

## Cron Integration (Optional)

Want automatic daily follow-suggestions in Discord/Telegram? I can create a cron job that runs `follow_tickers.py --digest` and posts results. Say the word.

---

## Thresholds Reference

| Ticker | Alert Below | Current (≈) |
|--------|------------|-------------|
| ZETA   | $15.00     | — |
| AMD    | $200.00    | — |
| AMZN   | $205.00    | — |
| HIMS   | $25.00     | — |
| OSCR   | $13.00     | — |
| SOFI   | $16.00     | — |
| KRKNF  | $5.50      | — |
| ONDS   | $8.00      | — |
| ABCL   | $4.00      | — |
| GRAB   | $3.50      | — |
| ASTS   | $60.00     | — |
| TE     | $4.50      | — |
| UBER   | $72.00     | — |
| NFLX   | $80.00     | — |
| NVO    | $40.00     | — |
| NKE    | $40.00     | — |
| SIDU   | $3.50      | — |
| **SMR**   | **$10.00** | **$11.70** |
| **FLNC**  | **$10.00** | **$12.27** |
| **RDW**   | **$7.00**  | **$8.96**  |

All thresholds trigger when price ≤ threshold. Hourly checks run via cron (outputs to Discord/Telegram; Slack pending config).

---

## Notes

- **xurl version**: v1.1.0 (Linux x86_64)
- **Auth**: `x-hermes` app (OAuth2), default user `fatc88`
- **Credits**: Depleted as of 2026-04-28 — all read endpoints blocked
- **Targeted accounts** (@EchoAnalysis, @mind1nvestor, @JoannisOrlandos) require credits to lookup

Once credits are restored, run `python3 ~/.hermes/scripts/follow_tickers.py --digest` to see recent posts and get follow suggestions.
