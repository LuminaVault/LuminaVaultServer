# KG Entities Structure & Deduplication Deep Dive — 2026-05-03

## Session Context

Cron run of `portfolio_threshold_alerts.py` at 2026-05-03 05:30:19 UTC produced no output. Investigation revealed all 5 monitored tickers (AMD, GOOGL, ZETA, RDW, ELF) were correctly suppressed by 24-hour deduplication. However, during diagnostics we **discovered and verified** two critical implementation details that contradict prior assumptions in the skill documentation.

---

## Finding 1: KG `entities.json` Structure — Flat Dict, Not a List

### Prior (incorrect) assumption
The skill documentation implied `entities.json` has a top-level `"entities"` array: `{"entities": [{...}, {...}]}`.

### Actual structure (confirmed 2026-05-03)
`entities.json` is a **flat dictionary** keyed by entity ID. Every entity is a direct child of the root object. There is no `"entities"` wrapper.

```json
{
  "snapshot_current_2026-04-30": { "type": "snapshot", ... },
  "ticker_AMD": { "type": "ticker", ... },
  "decision_026-04-29 Hermes Q&A — Portfolio System Build": {
    "id": "decision_026-04-29 Hermes Q&A — Portfolio System Build",
    "type": "decision",
    "properties": {
      "date": "2026-04-29",
      "tickers": ["AMD", "GOOGL", "ZETA", "OSCR", "HIMS", ...]
    }
  },
  ...
}
```

**Stats from this session:**
- Total keys (entities): 32
- Decision entities: 1 (`decision_026-04-29 Hermes Q&A — Portfolio System Build`)
- Decision tickers: 21 (includes AMD, ELF, GOOGL, RDW, ZETA — all 5 monitored tickers)

### Correct discovery code

```python
import json
with open('/opt/data/.hermes/knowledge_graph/entities.json') as f:
    data = json.load(f)  # data is a dict

# Iterate over all values (entities), not data['entities']
decisions = [entity for entity in data.values()
             if isinstance(entity, dict) and entity.get('type') == 'decision']

print(f"Found {len(decisions)} decision entities")
for d in decisions:
    props = d.get('properties', {})
    print(f"  {props.get('date')} → {props.get('tickers')}")
```

### Why this matters
If code assumes `data['entities']` exists, it will fail with `KeyError` or return an empty list, causing the entire monitoring system to see "no recent decisions" and skip all tickers silently.

---

## Finding 2: Deduplication Mechanics & State Format

### Alert state structure (verified)

```json
{
  "AMD": {
    "200.00_trim": "2026-05-03T02:30:48.372448+00:00"
  },
  "ELF": {
    "63.00_buy": "2026-05-02T14:00:41.548500+00:00"
  }
}
```

- **Inner key format:** `"{threshold:.2f}_{condition}"` — threshold formatted to **exactly 2 decimal places** (even if integer like `10.00`), underscore, then condition literal (`"buy"` or `"trim"`).
- **Suppression condition:** `datetime.utcnow() - last_alert < timedelta(hours=24)`
- **State update timing:** Only after **at least one platform send succeeds**. If both Discord and Telegram fail, the timestamp is not updated.

### Current cooldown status (this session)

| Ticker | Key            | Last Alert (UTC)       | Eligible (UTC)       | Remaining |
|--------|----------------|------------------------|----------------------|-----------|
| ELF    | 63.00_buy      | 2026-05-02 14:00:41   | 2026-05-03 14:00:41 | ~8h 28m   |
| AMD    | 200.00_trim    | 2026-05-03 02:30:48   | 2026-05-04 02:30:48 | ~20h 58m  |
| GOOGL  | 205.00_trim    | 2026-05-03 02:30:48   | 2026-05-04 02:30:48 | ~20h 58m  |
| ZETA   | 15.00_trim     | 2026-05-03 02:30:48   | 2026-05-04 02:30:48 | ~20h 58m  |
| RDW    | 10.00_buy      | 2026-05-03 02:30:48   | 2026-05-04 02:30:48 | ~20h 58m  |

### Log evidence of suppression

```
2026-05-03 05:30:19,472 - INFO - Detected 5 threshold crossing(s).
2026-05-03 05:30:20,060 - INFO - Suppressing alert for AMD: already sent within 24h (at 2026-05-03T02:30:48.372448+00:00)
2026-05-03 05:30:20,060 - INFO - Suppressing alert for GOOGL: already sent within 24h (...)
2026-05-03 05:30:20,061 - INFO - Suppressing alert for ZETA: already sent within 24h (...)
2026-05-03 05:30:20,061 - INFO - Suppressing alert for RDW: already sent within 24h (...)
2026-05-03 05:30:20,061 - INFO - Suppressing alert for ELF: already sent within 24h (...)
2026-05-03 05:30:20,061 - INFO - No new alerts to send after deduplication.
```

---

## Finding 3: Test Mode Behavior — Deduplication Still Applied

Running `python3 /opt/data/scripts/portfolio_threshold_alerts.py --test` **does NOT bypass** the 24-hour deduplication window. The `--test` flag only prevents actual platform sends and state updates; the suppression logic remains active.

**Consequence:** `--test` may produce no output even if prices are clearly crossed, making it unsuitable for debugging "are my thresholds working?" questions when the ticker was recently alerted.

**Workaround:** Manually delete the relevant keys from `alert_state.json` before running `--test`, or wait for the cooldown to expire. A robust fix would be to add a `--force-test` or `--skip-dedup` flag in a patched script version.

---

## Finding 4: Inactive Ticker (CELH) — KG Gating in Action

`portfolio_thresholds.json` contains 6 tickers, but only 5 are actively monitored:

- **CELH** (`buy $33.00`) is **silently skipped** because there is no KG decision entity for CELH in the past 90 days.
- The decision entity from 2026-04-29 covers 21 tickers, none of which is CELH.

**Rule:** A ticker is monitored **if and only if** it appears in **both**:
1. A recent KG decision entity (past 90 days)
2. `portfolio_thresholds.json`

Missing either condition → no monitoring, no log output, no alert.

---

## Verification Commands (from this session)

```bash
# 1. Check deduplication state
cat /opt/data/.hermes/portfolio/alert_state.json | python3 -m json.tool

# 2. Verify KG decisions (flat-dict structure!)
python3 -c "
import json
d = json.load(open('/opt/data/.hermes/knowledge_graph/entities.json'))
decisions = [v for v in d.values() if isinstance(v,dict) and v.get('type') == 'decision']
print(f'Decision count: {len(decisions)}')
for dec in decisions:
    p = dec.get('properties', {})
    print(f\"  {p.get('date')} | tickers={p.get('tickers')}\")
"

# 3. Check thresholds
cat /opt/data/.hermes/portfolio/portfolio_thresholds.json | python3 -m json.tool

# 4. Tail latest log (see suppression messages)
tail -n 30 /opt/data/.hermes/portfolio/threshold_alerts.log

# 5. Manual price check (sanity)
python3 -c "
import urllib.request, json
for t in ['AMD','GOOGL','ZETA','RDW','ELF']:
    url = f'https://query2.finance.yahoo.com/v8/finance/chart/{t}?range=1d&interval=1d'
    req = urllib.request.Request(url, headers={'User-Agent':'Mozilla/5.0'})
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    meta = d['chart']['result'][0]['meta']
    print(f'{t}: \${meta[\"regularMarketPrice\"]} (as of {meta[\"regularMarketTime\"]})')
"
```

---

## Implications for Patching / Future Work

1. **Script `--test` flag enhancement** should add a `--skip-dedup` or `--force` mode to force alert generation regardless of `alert_state.json`. Current behavior renders `--test` useless for validating threshold logic during development.

2. **KG discovery code** in the script should defensively handle both flat-dict and potential `{"entities": [...]}` formats to be forward-compatible, or explicitly assert the expected structure with a clear error message.

3. **Monitoring eligibility check** (KG ∩ thresholds) should be explicitly logged as part of the "Monitoring N ticker(s)" message to make it obvious when a ticker is excluded due to missing KG decision vs. missing threshold.

4. **CELH case** demonstrates a common user confusion: adding a threshold alone is insufficient. Consider adding a validation command that lists all thresholded tickers and flags those without recent KG decisions.
