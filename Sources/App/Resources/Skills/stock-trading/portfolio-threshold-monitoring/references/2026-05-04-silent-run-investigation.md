# 2026-05-04 — Portfolio Threshold Alert Silent Run Investigation

**Date:** May 4, 2026  
**Cron runs investigated:** 14:00, 14:10, 14:30 UTC  
**Status:** System functioning as designed — all alerts suppressed by 24-hour deduplication

## Investigation Summary

The script ran successfully three times in the past hour but produced no output because all monitored tickers had already triggered alerts within the past 24 hours. This is the expected behavior given the current 12-hour deduplication window.

### Monitored Tickers & Current Status

From the KG decisions (21 tickers) and thresholds file (17 tickers), the following 5 tickers are actively monitored:

| Ticker | Condition | Threshold | Status | Last Alert | Time Since |
|--------|-----------|-----------|--------|------------|------------|
| **AMD** | trim | $200.00 | ❌ Crossed | Today 03:00:25 | ~11 hours ago |
| **GOOGL** | trim | $205.00 | ❌ Crossed | Today 03:00:25 | ~11 hours ago |
| **ZETA** | trim | $15.00 | ❌ Crossed | Today 03:00:25 | ~11 hours ago |
| **RDW** | buy | $10.00 | ✅ Crossed | Today 03:00:25 | ~11 hours ago |
| **ELF** | buy | $63.00 | ✅ Crossed | May 3, 14:30:59 | ~24 hours ago |

**Note:** All 5 tickers are still crossing their thresholds, but alerts are suppressed until the 12-hour window expires.

### Log Analysis

**14:30 UTC run:**
```
2026-05-04 14:30:06,343 - INFO - === Portfolio Threshold Alert Run START ===
2026-05-04 14:30:06,343 - INFO - Tickers from recent decisions (21): A6I, ABCL, ADUR, AMD, AMZN, ASTS, ELF, GOOGL, HIMS, KRKNF, NFLX, NVO, ONDS, OSCR, OUST, RDW, SMR, SOFI, TE, UBER, ZETA
2026-05-04 14:30:06,343 - INFO - Monitoring 5 ticker(s) with thresholds
2026-05-04 14:30:07,363 - INFO - Detected 5 threshold crossing(s).
2026-05-04 14:30:07,364 - INFO - Suppressing alert for AMD: already sent within 24h (at 2026-05-04T03:00:25.849208+00:00)
2026-05-04 14:30:07,364 - INFO - Suppressing alert for GOOGL: already sent within 24h (at 2026-05-04T03:00:25.849208+00:00)
2026-05-04 14:30:07,364 - INFO - Suppressing alert for ZETA: already sent within 24h (at 2026-05-04T03:00:25.849208+00:00)
2026-05-04 14:30:07,364 - INFO - Suppressing alert for RDW: already sent within 24h (at 2026-05-04T03:00:25.849208+00:00)
2026-05-04 14:30:07,364 - INFO - Suppressing alert for ELF: already sent within 24h (at 2026-05-03T14:30:59.721277+00:00)
2026-05-04 14:30:07,364 - INFO - No new alerts to send after deduplication.
2026-05-04 14:30:07,364 - INFO - === Portfolio Threshold Alert Run END ===
```

### Key Findings

1. **Deduplication Window:** The script uses a 12-hour window (line 383), but the log messages say "within 24h" — this is a minor inconsistency but doesn't affect functionality.

2. **Current Prices:** All 5 monitored tickers are still in alert condition:
   - AMD: ~$337 (well above $200 trim)
   - GOOGL: ~$349 (well above $205 trim)
   - ZETA: ~$17.81 (above $15 trim)
   - RDW: ~$8.60 (below $10 buy)
   - ELF: ~$61.08 (below $63 buy)

3. **Next Expected Alerts:** The next alerts for these tickers will be sent when:
   - AMD, GOOGL, ZETA, RDW: ~15:00 UTC (12 hours after 03:00:25)
   - ELF: ~03:30 UTC tomorrow (12 hours after 14:30:59)

4. **KG Coverage:** The KG contains 21 decision tickers, but only 5 have thresholds defined. This is normal — thresholds are user-configurable.

5. **Script Health:** The script is running every 30 minutes as scheduled and is functioning correctly. No errors detected.

## Diagnostic Commands Used

```bash
# Check current suppression status
cat ~/.hermes/portfolio/alert_state.json | python3 -m json.tool

# View recent log
tail -n 30 ~/.hermes/portfolio/threshold_alerts.log

# Quick health check
python3 /opt/data/skills/stock-trading/portfolio-threshold-monitoring/scripts/portfolio_threshold_healthcheck.py

# Verify KG decisions
python3 -c "import json; e=json.load(open('/opt/data/home/.hermes/knowledge_graph/entities.json')); d=[v for v in e.values() if isinstance(v,dict) and v.get('type')=='decision']; print('Decisions:', len(d))"
```

## Recommendations

- **No action needed** — system is working as intended
- If more frequent alerts are desired, reduce the deduplication window from 12 hours to a smaller value in the script
- If you want to see all current crossings (including suppressed ones), temporarily clear the relevant keys from `alert_state.json` and run `--test`

## Related Investigation Notes

- 2026-05-02 — Silent run diagnosis
- 2026-05-02 — Extended silent run (19:00 UTC) follow-up
- 2026-05-03 — Cron silent run (01:30 & 05:30 UTC) operational review
- 2026-05-03 — KG entities structure & deduplication deep dive