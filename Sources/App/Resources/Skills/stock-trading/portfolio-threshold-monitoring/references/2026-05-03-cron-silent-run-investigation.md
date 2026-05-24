# Operational Findings — May 03, 2026 Cron Investigation

**Cron job:** `portfolio-threshold-alerts` (every 30 min)  
**Script:** `portfolio_threshold_alerts.py` (445 lines)  
**Session:** Diagnosed "script ran successfully but produced no output"

## Root Cause

All monitored tickers were under 24-hour deduplication cooldowns. The script operated correctly — suppression is expected behavior.

## Key Operational Facts

### Dual Script Locations
- **Primary:** `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py`
- **Symlink (cron):** `/opt/data/scripts/portfolio_threshold_alerts.py` → primary

Edit the primary; the symlink mirrors automatically.

### HOME Directory Nuance
Hermes sets `HOME=/opt/data/home` (not `/home`). Tilde expansion and `Path.home()` use this value. When documentation says `~/.hermes/...`, it resolves to `/opt/data/home/.hermes/...`.

### KG Entities Path
Actual: `/opt/data/home/.hermes/knowledge_graph/entities.json`  
Documented as: `~/.hermes/knowledge_graph/entities.json` — functionally identical if `$HOME` is correct, but use absolute path in scripts to avoid ambiguity.

### Current Deduplication State (May 03 01:30 UTC)

```
Now: 2026-05-03T01:31:39+00:00

AMD  200.00_trim: SUPPRESSED → next 02:30 UTC (~59 min remaining)
GOOGL 205.00_trim: SUPPRESSED → next 02:30 UTC (~59 min remaining)
ZETA 15.00_trim:  SUPPRESSED → next 02:30 UTC (~59 min remaining)
RDW  10.00_buy:   SUPPRESSED → next 02:30 UTC (~59 min remaining)
ELF  63.00_buy:    SUPPRESSED → next 14:00 UTC (~12.5 h remaining)
```

All five monitored tickers are crossing thresholds but suppressed.

### Live Prices (verified Yahoo Finance)

| Ticker | Price | Threshold | Condition |
|--------|-------|-----------|-----------|
| AMD    | $360.54 | $200.00 | trim (↑) |
| GOOGL  | $385.69 | $205.00 | trim (↑) |
| ZETA   | $18.60  | $15.00  | trim (↑) |
| RDW    | $9.34   | $10.00  | buy  (↓) |
| ELF    | $60.49  | $63.00  | buy  (↓) |

### KG Gating

- Recent decisions (90d): 1 decision from 2026-04-29 with 21 tickers
- Monitored intersection: 5 tickers have both KG decision and threshold entry
- Inactive threshold: CELH ($33 buy) — no recent KG decision, so excluded

## Quick Verification Commands

```bash
# 1. Show deduplication windows
python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
state = json.load(open('/opt/data/home/.hermes/portfolio/alert_state.json'))
for ticker, entries in sorted(state.items()):
    for key, ts in sorted(entries.items()):
        last = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
        next_time = last + datetime.timedelta(hours=24)
        remaining = (next_time - now).total_seconds()
        print(f'{ticker} {key}: next={next_time.strftime(\"%m-%d %H:%M\")} remaining={int(remaining//60)}min')
"

# 2. Tail latest log (shows suppression reasons)
tail -20 /opt/data/home/.hermes/portfolio/threshold_alerts.log

# 3. Verify KG decisions exist
python3 -c "
import json, datetime
p = '/opt/data/home/.hermes/knowledge_graph/entities.json'
e = json.load(open(p))
ents = list(e.values()) if isinstance(e, dict) else e
decs = [v for v in ents if isinstance(v,dict) and v.get('type')=='decision']
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)
recent = [d for d in decs if datetime.datetime.fromisoformat(d.get('properties',{}).get('date','2000')) > cutoff]
print(f'Recent decisions: {len(recent)}')
tickers = set()
for d in recent: tickers.update(d.get('properties',{}).get('tickers',[]))
print('Tickers:', sorted(tickers))
"

# 4. Manual price check
python3 -c "
import urllib.request, json
for t in ['AMD','GOOGL','ZETA','RDW','ELF']:
    url = f'https://query2.finance.yahoo.com/v8/finance/chart/{t}?range=1d&interval=1d'
    req = urllib.request.Request(url, headers={'User-Agent':'Mozilla/5.0'})
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(f'{t}: \${d[\"chart\"][\"result\"][0][\"meta\"][\"regularMarketPrice\"]}')
"
```

## Test-Mode Limitation

`python3 /opt/data/scripts/portfolio_threshold_alerts.py --test` respects the 24-hour deduplication window. If all monitored tickers are suppressed, test mode prints nothing. This can mask threshold crossings during debugging.

**Workaround:** Temporarily clear relevant keys from `alert_state.json` before running `--test`, or wait for cooldown expiry.

**Suggested script improvement:** Add a `--force` flag that bypasses deduplication for diagnostics.

## Next Alert Windows

- **02:30 UTC today** (May 03): AMD, GOOGL, ZETA, RDW become eligible (if prices still crossed)
- **14:00 UTC today** (May 03): ELF becomes eligible (if price still below $63)

## Known Gaps

1. **CELH not monitored** despite threshold entry — no recent KG decision. Either create decision entity or accept exclusion.
2. **ELF price data** previously showed $0.00 (stale); now resolved with fresh fetch.
3. **Script path confusion** between primary and symlink locations documented in skill; now clarified.

## Cron Job Details

```json
{
  "id": "a35b76eda07c",
  "name": "portfolio-threshold-alerts",
  "enabled": true,
  "schedule": "*/30 * * * *",
  "script": "portfolio_threshold_alerts.py",
  "last_run_at": "2026-05-03T01:01:03+00:00",
  "next_run_at": "2026-05-03T02:00:00+00:00",
  "last_status": "ok"
}
```

A second hourly variant exists (`portfolio-threshold-alerts-hourly`) but delegates to the same script.
