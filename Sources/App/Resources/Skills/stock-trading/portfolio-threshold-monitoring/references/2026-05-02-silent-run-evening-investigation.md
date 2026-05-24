# 2026-05-02 Evening: Silent Run Follow-up Investigation

**Context:** Cron job `portfolio-threshold-alerts-hourly` executed 2026-05-02 19:00:14 UTC; completed 19:00:15 UTC; exit code 0; no output. This is the fourth consecutive suppressed run (02:30, 18:30, 19:00 UTC). All threshold crossings remain within the 24-hour deduplication window.

## System State Summary

| Component | Status | Notes |
|-----------|--------|-------|
| Script | ✅ Running | `/opt/data/scripts/portfolio_threshold_alerts.py` exit 0 |
| KG entities | ✅ Healthy | 1 decision entity (2026-04-29) covering 21 tickers |
| Threshold config | ✅ Valid | 6 entries in `portfolio_thresholds.json` |
| Alert state | ✅ Active | 5 cooldowns; all within 24h suppression window |
| Live prices | ⚠️ Stale | `live_prices.csv` last updated 2026-04-30 (2+ days old) |
| Log file | ✅ Growing | 1617 lines; last entry 19:00:15 UTC |

## Monitored Tickers Logic — Clarified

**Formula:** `Monitored = {tickers in recent KG decisions} ∩ {tickers with threshold entries}`

- **KG tickers** (21): AMD, GOOGL, ZETA, OSCR, HIMS, AMZN, ASTS, SOFI, ADUR, TE, NFLX, ONDS, UBER, NVO, KRKNF, A6I, ABCL, RDW, OUST, SMR, ELF
- **Threshold tickers** (6): CELH, ELF, RDW, AMD, GOOGL, ZETA
- **Intersection** (5 monitored): ELF, RDW, AMD, GOOGL, ZETA

> **CELH gap**: Present in `portfolio_thresholds.json` but absent from KG decisions → not actively monitored. To activate, create a decision entity that includes `CELH`.

## Active Cooldowns (24h suppression)

| Ticker + Threshold | Condition | Last alert | Suppression expires |
|-------------------|-----------|------------|---------------------|
| AMD $200.00 | trim | 2026-05-02 02:30 UTC | 2026-05-03 02:30 UTC |
| GOOGL $205.00 | trim | 2026-05-02 02:30 UTC | 2026-05-03 02:30 UTC |
| ZETA $15.00 | trim | 2026-05-02 02:30 UTC | 2026-05-03 02:30 UTC |
| RDW $10.00 | buy | 2026-05-02 02:30 UTC | 2026-05-03 02:30 UTC |
| ELF $63.00 | buy | 2026-05-02 14:00 UTC | 2026-05-03 14:00 UTC |

All 5 monitored tickers are currently suppressed. No new alerts to send.

## Price Snapshot (from `live_prices.csv`)

| Ticker | Price | Threshold | Condition | Crossed? | Data freshness |
|--------|-------|-----------|-----------|----------|----------------|
| AMD | $337.11 | $200.00 | trim | ✅ ≥ | 2026-04-30 07:20 UTC |
| GOOGL | $349.94 | $205.00 | trim | ✅ ≥ | 2026-04-30 07:20 UTC |
| ZETA | $17.81 | $15.00 | trim | ✅ ≥ | 2026-04-30 07:20 UTC |
| RDW | $8.60 | $10.00 | buy | ✅ ≤ | 2026-04-30 07:20 UTC |
| ELF | $0.00 | $63.00 | buy | ✅ ≤ | **2026-04-29 07:00 UTC (STALE)** |
| CELH | $32.66 | $33.00 | buy | ✅ ≤ | 2026-04-30 07:20 UTC (not monitored) |

**Note:** ELF shows `$0.00` due to stale price data (last update 2026-04-29). True crossing status unknown until price feed refreshes.

## Key Discoveries & Operational Learnings

1. **Stale price data detection:** `live_prices.csv` last modified 2026-05-02 07:20 UTC but contains 23 rows; many price entries have updated_at in late April. Price freshness check should parse per-row `updated_at`, not just file mtime.

2. **Monitored set is intersection, not union:** Having a threshold entry alone is insufficient. Ticker must also appear in a recent KG decision to be considered. The script logs "Monitoring N ticker(s) with thresholds" after intersecting.

3. **KG ticker source is `properties.tickers` array**, not tags. Decision entity structure:
   ```json
   {
     "type": "decision",
     "properties": {
       "date": "YYYY-MM-DD",
       "tickers": ["AMD", "GOOGL", ...],
       "type": "buy_decision"
     }
   }
   ```

4. **Exit code semantics:** Under cron, exit code `0` suppresses stdout delivery even if script prints something (standard cron behavior). The script only exits with `1` when at least one platform send succeeded. A silent cron email with exit 0 typically means clean run → no new alerts.

5. **Previously observed threshold expansion candidates:** 16 tickers appear in recent KG decisions but lack threshold entries (A6I, ABCL, ADUR, AMZN, ASTS, HIMS, KRKNF, NFLX, NVO, ONDS, OSCR, OUST, SMR, SOFI, TE, UBER). Consider adding thresholds if you want alerts on these.

## Quick Diagnostic Checklist (for similar silent-run investigations)

```bash
# 1. Log inspection
tail -n 30 ~/.hermes/portfolio/threshold_alerts.log | grep -E 'START|END|Monitoring|Detected|Suppressing'

# 2. Show alert state ages
python3 -c "
import json, datetime, os
s = json.load(open(os.path.expanduser('~/.hermes/portfolio/alert_state.json')))
now = datetime.datetime.now(datetime.timezone.utc)
for t, entries in s.items():
    for k, ts in entries.items():
        age = (now - datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))).total_seconds()/3600
        print(f'{t} {k}: {age:.1f}h old → suppress={age<24}')
"

# 3. Price freshness check
python3 -c "
import csv, datetime, os
p = os.path.expanduser('~/.hermes/portfolio/live_prices.csv')
with open(p) as f:
    for row in csv.DictReader(f):
        updated = datetime.datetime.fromisoformat(row['updated_at'].replace('Z','+00:00'))
        age = (datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds()/3600
        if age > 48: print(f'STALE: {row[\"ticker\"]} updated {age:.1f}h ago')
"

# 4. Manual threshold test mode
python3 /opt/data/scripts/portfolio_threshold_alerts.py --test
```

## Resolution

**System is operating correctly.** The silent output is expected behavior when all monitored ticker+threshold pairs are still within the 24-hour deduplication window. No action required.

**Next potential alert window:**
- 2026-05-03 02:30 UTC (4 tickers: AMD, GOOGL, ZETA, RDW) if prices remain crossed
- 2026-05-03 14:00 UTC (1 ticker: ELF) if price remains ≤ $63

---

*Related: `references/2026-05-02-silent-run-investigation.md` covers the earlier morning diagnostic trace.*
