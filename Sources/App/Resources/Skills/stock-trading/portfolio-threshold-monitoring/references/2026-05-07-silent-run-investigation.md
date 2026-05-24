# Portfolio Threshold Monitoring — Silent Cron Run Investigation (May 07, 2026)

## Context

- **Date:** 2026-05-07 02:00-02:05 UTC
- **Trigger:** Cron job executed but produced no stdout output, despite expectations of threshold crossings.
- **Goal:** Diagnose whether the system is functioning correctly or if there's an issue.

## Investigation Steps

### 1. Initial Attempt to Run Script

**Command attempted:** `$HERMES_HOME/scripts/portfolio_threshold_alerts.py --test=false`

**Issue:** Script not found at expected path, and argument `--test=false` invalid.

**Resolution:** 
- Located script at `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py`
- Correct invocation: `./portfolio_threshold_alerts.py` (production) or `./portfolio_threshold_alerts.py --test` (test mode)
- The `--test` flag is a boolean switch — it takes no value. Using `--test=false` causes an error.

### 2. Script Execution and Output Analysis

**Production run:** `./portfolio_threshold_alerts.py` → exit code 0, no stdout output.

**Test run:** `./portfolio_threshold_alerts.py --test` → prints alerts to stdout, but respects deduplication.

**Key insight:** Production runs are silent by design. All information is logged to `threshold_alerts.log`. No stdout output does not indicate failure.

### 3. Log File Examination

**Log path:** `/opt/data/home/.hermes/portfolio/threshold_alerts.log`

**Recent entries (02:00 and 02:01 runs):**
```
2026-05-07 02:00:55,774 - INFO - === Portfolio Threshold Alert Run START ===
2026-05-07 02:00:55,774 - INFO - Tickers from recent decisions (21): A6I, ABCL, ADUR, AMD, AMZN, ASTS, ELF, GOOGL, HIMS, KRKNF, NFLX, NVO, ONDS, OSCR, OUST, RDW, SMR, SOFI, TE, UBER, ZETA
2026-05-07 02:00:55,774 - INFO - Monitoring 5 ticker(s) with thresholds
2026-05-07 02:00:56,325 - INFO - Detected 5 threshold crossing(s).
2026-05-07 02:00:56,325 - INFO - Suppressing alert for AMD: already sent within 24h (at 2026-05-06T23:01:39.677091+00:00)
2026-05-07 02:00:56,325 - INFO - Suppressing alert for GOOGL: already sent within 24h (at 2026-05-06T23:01:39.677091+00:00)
2026-05-07 02:00:56,325 - INFO - Suppressing alert for ZETA: already sent within 24h (at 2026-05-06T23:01:39.677091+00:00)
2026-05-07 02:00:56,325 - INFO - Suppressing alert for RDW: already sent within 24h (at 2026-05-06T23:01:39.677091+00:00)
2026-05-07 02:00:56,325 - INFO - Suppressing alert for ELF: already sent within 24h (at 2026-05-06T23:01:39.677091+00:00)
2026-05-07 02:00:56,325 - INFO - No new alerts to send after deduplication.
2026-05-07 02:00:56,325 - INFO - === Portfolio Threshold Alert Run END ===
```

**Finding:** All 5 monitored tickers (AMD, GOOGL, ZETA, RDW, ELF) crossed their thresholds, but all alerts were suppressed because they were already sent within the past 24 hours (last alert at 2026-05-06T23:01:39.677091+00:00). This is expected behavior.

### 4. Verification of System Health

- **KG entities:** 21 recent decisions from past 90 days, covering all monitored tickers.
- **Thresholds:** Configured for 6 tickers (CELH, ELF, RDW, AMD, GOOGL, ZETA).
- **Alert state:** Contains recent entries confirming alerts were sent.
- **Prices:** Fetched successfully from Yahoo Finance.
- **Cron schedule:** Running every 30 minutes as expected.

### 5. Root Cause

No issue found. The system is functioning correctly:
- Threshold crossings occurred as expected.
- Deduplication window (24 hours) suppressed alerts because the same tickers crossed thresholds within the cooldown period.
- Production run produced no stdout because alerts were suppressed and no test mode was used.

### 6. Action Items

- **None.** System is healthy.
- **Documentation update needed:** Clarify script invocation and output expectations in the skill documentation.

## Lessons Learned

1. **Script path resolution:** The script may be found at `/opt/data/home/.hermes/scripts/` rather than `$HERMES_HOME/scripts/`. Always check both locations.
2. **Argument parsing:** `--test` is a boolean flag; it does not accept a value. `--test=false` causes an error.
3. **Output expectations:** Production runs are silent (no stdout). All diagnostic information is in the log file.
4. **Deduplication:** Even in test mode, alerts may be suppressed if sent within the deduplication window. To force test output, temporarily clear `alert_state.json`.
5. **Cron job verification:** When a cron job appears to produce no output, check the log file first before assuming failure.

## Commands Used

```bash
# Locate script
ls -la /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py

# Run in test mode (shows what would be sent)
python3 /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py --test

# Check log
tail -n 30 /opt/data/home/.hermes/portfolio/threshold_alerts.log

# Verify KG decisions
python3 -c "import json; e=json.load(open('/opt/data/home/.hermes/knowledge_graph/entities.json')); d=[v for v in e.values() if isinstance(v,dict) and v.get('type')=='decision']; print(f'Decisions: {len(d)}')"

# Check thresholds
cat /opt/data/home/.hermes/portfolio/portfolio_thresholds.json

# Check alert state
cat /opt/data/home/.hermes/portfolio/alert_state.json
```

## Related Resources

- Skill: `portfolio-threshold-monitoring` (this skill)
- Health check script: `scripts/portfolio_threshold_healthcheck.py`
- Log file: `~/.hermes/portfolio/threshold_alerts.log`
- State file: `~/.hermes/portfolio/alert_state.json`
- KG entities: `~/.hermes/knowledge_graph/entities.json`