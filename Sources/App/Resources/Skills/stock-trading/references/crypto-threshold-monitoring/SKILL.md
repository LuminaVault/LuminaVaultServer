---
name: crypto-threshold-monitoring
description: Cryptocurrency price threshold alerts (BTC, ETH, SUI) to Discord on a 2-hour schedule
version: 1.0.0
author: Hermes Agent
license: MIT
---

# Crypto Threshold Monitoring

Monitors cryptocurrency prices and sends an alert when any price falls at or below a user-defined threshold. Uses CoinGecko's free public API (no authentication required). Alerts are sent every 2 hours to a designated Discord channel.

## Files

- **Script**: `~/.hermes/scripts/crypto_alert.py`
- **Cron job**: One job (Discord, every 2 hours)

## Cryptocurrencies & Thresholds

| Symbol | Name      | Threshold | Current (≈) | Notes |
|--------|-----------|-----------|-------------|-------|
| BTC    | Bitcoin   | ≤ $75,000 | ~$76,320    | |
| ETH    | Ethereum  | ≤ $2,200  | ~$2,288     | |
| SUI    | Sui       | ≤ $0.95   | ~$0.92      | Currently below threshold |

Thresholds are hard-coded in the script. To change them, edit the `THRESHOLDS` dict inside `crypto_alert.py`.

## How It Works

1. The script queries CoinGecko's `/simple/price` endpoint for BTC, ETH, SUI in USD
2. Compares each crypto's current price to its threshold
3. If any crypto ≤ threshold: Emits a formatted markdown alert with breach details (exit code 1)
4. If all clear: Emits nothing (exit code 0) — cron delivers silence
5. Cron job runs every 2 hours and delivers stdout to the assigned Discord channel

## Channel Routing

- **Discord**: Job delivers to `discord:1498815544898617505` (channel `<#1498815544898617505>`)
- No Telegram or Slack copies currently configured

To add more platforms, create duplicate cron jobs with the same script but different `--deliver` targets.

## Adding/Removing Cryptocurrencies

Edit `~/.hermes/scripts/crypto_alert.py`:

1. Add symbol to `THRESHOLDS` dict with threshold price
2. Add CoinGecko ID to `COINGECKO_IDS` dict (find IDs at coingecko.com)
3. Optional: update the alert formatting in `format_alert()` if you want custom display

Supported: Any cryptocurrency listed on CoinGecko with a USD price.

## Testing

Run manually:
```bash
python3 ~/.hermes/scripts/crypto_alert.py
```

Expected output on breach:
```
**🚨 CRYPTO ALERT — Threshold Breached**

🟡 **SUI**  Threshold ≤ $0.95
   Current:  $0.92

_Checked: 3 cryptos | Source: CoinGecko_
```

Trigger the cron job manually:
```bash
hermes cron run e672212d6a64
```

## Job Reference

| Job Name | Schedule | Job ID | Deliver |
|-----------|----------|--------|---------|
| Crypto Alert — BTC/ETH/SUI (every 2h) | `0 */2 * * *` | `e672212d6a64` | `discord:1498815544898617505` |

## Maintenance

- **CoinGecko rate limits are aggressive:** Free tier enforces ~10–30 calls/minute globally per IP across ALL scripts/cron jobs. Even a single-call script can hit 429 if other services are polling. See `references/coingecko-rate-limit-observed.md` for test evidence.
- **No retry logic:** Current `crypto_alert.py` fails hard on HTTP 429 without backoff or retry, causing exit 1 and false-positive alerts.
- **Error vs breach ambiguity:** Both API failures and real threshold breaches return exit code 1. The wrapper forwards ALL stdout+stderr to Discord, so infrastructure errors (429, network timeouts) are posted as if they were real alerts. See Pitfall 6 below.

## Pitfalls

### Pitfall 6: Rate-Limit Errors Trigger False-Positive Discord Alerts
**Symptom:** Discord receives a message like `ERROR: Failed to fetch prices — HTTP Error 429: Too Many Requests`, but the cron job exits 1, making it look like an alert condition.

**Cause:** `crypto_alert.py` treats any fetch exception as fatal (exit 1) and prints the error to stdout+stderr. The wrapper (`crypto_alert_wrapper.sh`) captures *all* output and forwards it to Discord unconditionally on exit 1.

**Impact:** Noise in the alert channel; hard to distinguish real breaches from API issues.

**Fix — Option A (wrapper-level filtering):** Modify wrapper to detect error messages and suppress Discord delivery. See `references/wrapper-error-filtering.md` for a minimal patch.

**Fix — Option B (script-level resilience):** Add retry+backoff to `crypto_alert.py` to survive transient 429s. See `scripts/crypto_alert_with_retry.py` for a drop-in replacement that:
- Retries up to 3 times with exponential backoff (2s → 4s → 8s)
- Only exits 1 on final failure (after retries exhausted)
- Keeps stdout clean — only emits the alert markdown on real breaches; errors stay on stderr

**Fix — Option C (separate error stream):** Change wrapper to send *only* stdout to Discord and log stderr to a file for cron to capture separately. Current `2>&1` merge blurs the distinction.

## Support Files

This skill ships operational support files in the skill directory:

- **`references/coingecko-rate-limit-observed.md`** — observed HTTP 429 behavior on free tier + recommended backoff strategy
- **`references/wrapper-error-filtering.md`** — minimal wrapper patch to distinguish errors from real alerts
- **`scripts/crypto_alert_with_retry.py`** — drop-in replacement for `crypto_alert.py` with exponential backoff and clean error separation

To use the fixed script, overwrite `~/.hermes/scripts/crypto_alert.py` with `scripts/crypto_alert_with_retry.py` or symlink it.

## Related

- **Stock alerts**: See `stock-threshold-monitoring` skill for equity threshold alerts (hourly, multi-platform)
- **X-based ticker discovery**: See `x-social-monitor` and `~/.hermes/scripts/follow_tickers.py` for discovering crypto/stock accounts to follow on X
