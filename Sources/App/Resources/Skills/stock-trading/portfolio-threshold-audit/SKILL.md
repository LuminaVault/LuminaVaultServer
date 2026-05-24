---
name: portfolio-threshold-audit
description: Audit and maintain KG-powered portfolio threshold alerts — validate configuration health, detect orphaned thresholds, and verify monitoring coverage.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [stock-trading, portfolio, monitoring, maintenance, audit]
    related_skills: [cron-deployment]
---

# Portfolio Threshold Audit — Health Checks & Maintenance

This skill governs periodic validation of the KG-powered threshold alert system. It helps ensure the monitoring pipeline is complete: every configured threshold must correspond to a ticker that appears in a recent KG decision entity (default: past 90 days). It also surfaces configuration drift, stale thresholds, and orphaned entries that would otherwise be silently ignored.

## When to Use

- **Initial setup verification** — After deploying `portfolio_threshold_alerts.py`, run an audit to confirm all intended tickers are being monitored.
- **Scheduled maintenance** — Weekly or monthly health checks to detect drift (e.g., tickers that fell out of KG scope but still have thresholds).
- **Post-KG-update** — After major research/decision ingestion, validate the threshold coverage remains correct.
- **No-alert troubleshooting** — When the alert script produces no output but you expect activity, audit to find mismatches.

## Core Audit Checks

| Check | Purpose | Failure Mode |
|-------|---------|--------------|
| **Threshold→KG coverage** | Every ticker in `portfolio_thresholds.json` must appear in at least one decision entity from the past N days (default 90) | Orphaned threshold — ticker never monitored, alerts impossible |
| **KG→Threshold reverse coverage** *(optional)* | Every recent decision ticker with a threshold should have a configured threshold | Unmonitored decision — ticker discovered but no threshold set (by design) |
| **Price fetch sanity** | Spot-check that Yahoo Finance returns live prices for all monitored tickers | API/network issues or ticker normalization problems |
| **State file health** | `alert_state.json` must be valid JSON and writable | State corruption prevents deduplication |
| **Platform token presence** | `DISCORD_BOT_TOKEN` and/or `TELEGRAM_BOT_TOKEN` present in `.env` if delivery expected | Alerts silently fail to deliver |

## Primary Command

```bash
# Run full audit (uses default 90-day window)
python3 ~/.hermes/scripts/audit_threshold_config.py

# Custom window (e.g., 30 days)
python3 ~/.hermes/scripts/audit_threshold_config.py --days 30

# Test mode — shows what would be fixed without mutating anything
python3 ~/.hermes/scripts/audit_threshold_config.py --test
```

**Script location:** `~/skills/stock-trading/portfolio-threshold-audit/scripts/audit_threshold_config.py`

## Output Interpretation

### Healthy State
```
✅ All 6 configured thresholds are covered by recent KG decisions.
Monitored: AMD, CELH, ELF, GOOGL, RDW, ZETA
```

### Orphaned Thresholds Detected
```
⚠️  2 orphaned threshold(s) — not in recent KG decisions:
   CELH ($33.00 buy) — last decision: none
   UNKNOWN ($42.00 trim) — last decision: none
Action: Add to a KG decision entity OR remove from thresholds.
```

### Stale Thresholds (no recent decision but once had one)
```
📦 1 stale threshold (last decision >90d ago):
   OLD: $15.00 trim — last seen in decision on 2025-12-01
Consider refreshing research or lowering coverage window.
```

## Remediation Pathways

1. **Orphaned ticker wanted** — Create or update a `decision` entity in `knowledge_graph/entities.json` that includes the ticker in its `tickers` array, with a `date` within the coverage window.
2. **Orphaned ticker not wanted** — Delete the threshold entry from `portfolio_thresholds.json`.
3. **Stale ticker** — Either refresh the KG decision (new research/conversation creating a decision entity) or acknowledge that it's out of scope by removing the threshold.

## Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Forgetting orphaned thresholds after manual config edit | Script runs silently because the ticker is never in the KG ticker set | Run `audit_threshold_config.py` after any threshold change |
| Relying solely on "no output" as signal | Assuming all-clear when actually no thresholds are being monitored at all (empty intersection) | Audit periodically to confirm monitored set is non-empty |
| Overlooking ticker normalization mismatches | Threshold uses `A6I` but KG uses `A6I.F` and they don't match | The audit script applies the same `YAHOO_NORMALIZE` mapping as the alert script; ensure consistency |

## Integration

- **Pre-cron sanity check** — Wrap the main alert script with a pre-check: if audit finds orphaned thresholds, log a warning and exit non-zero so the cron job is marked as needing attention.
- **Weekly digest** — Include audit summary in a periodic maintenance report.

## Reference Implementation

See `scripts/audit_threshold_config.py` in this skill's directory for the canonical audit script. It mirrors the ticker-discovery and normalization logic from `portfolio_threshold_alerts.py` to ensure consistent coverage detection.

## Related Skills

- **cron-deployment** — Governs deployment and operation of the alert script itself; its `references/portfolio-threshold-alerts.md` documents the full system architecture, deduplication logic, and cron job setup. The audit script complements it by validating configuration *before* deployment.
