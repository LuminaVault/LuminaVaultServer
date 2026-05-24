# Portfolio Threshold Monitoring — Script File Divergence (May 03, 2026)

## Diagnostic Summary

During routine inspection, discovered that the two script locations documented as "primary + symlink" are in fact **two independent files** — not a symlink relationship.

## Findings

| Property | `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py` | `/opt/data/scripts/portfolio_threshold_alerts.py` |
|----------|---------------------------------------------------------------|---------------------------------------------------|
| Size | 19,157 bytes | 19,364 bytes |
| Modified | 2026-04-30 08:59 UTC | 2026-05-02 22:01 UTC |
| Inode | 522970 | 511026 |
| Is symlink | No | No |

File sizes differ by 207 bytes. The `/opt/data/scripts/` version includes an `HERMES_HOME` environment variable check at startup that is absent from the primary. This suggests the `/opt/data/scripts/` copy was edited in place after deployment, intentionally diverging from the canonical version.

## Root Cause Analysis

The skill documentation states: **"The script lives at `/opt/data/home/.hermes/scripts/` and is symlinked to `/opt/data/scripts/` for cron accessibility. Always edit the primary location; the symlink mirrors it."**

The filesystem inspection reveals:
- No symlink exists at `/opt/data/scripts/portfolio_threshold_alerts.py`
- The `/opt/data/scripts/` version is a standalone file with additional code

This indicates either:
1. The symlink was replaced with an independent copy during a previous edit, or
2. The deployment process created two physical files instead of a symlink

The `/opt/data/scripts/` version contains a HERMES_HOME env var guard (added ~May 2), likely to handle cron PATH resolution issues. This modification was not propagated to the primary script.

## Implications

- **Cron behavior uncertainty:** Without verifying which file the cron job actually executes, we cannot be certain which logic path runs.
- **Configuration drift:** The two files will continue to diverge if both are maintained independently.
- **Maintenance risk:** Documented procedures ("edit primary, symlink mirrors") are invalid; editing only one location breaks consistency.

## Remediation

1. **Determine cron target:** Verify which file path appears in the crontab entry:
   ```bash
   grep portfolio_threshold_alerts /etc/crontab 2>/dev/null || echo "Check systemd timers or user crontabs"
   ```

2. **Choose canonical location:**
   - If cron uses `/opt/data/scripts/…` → make it a symlink to the primary, then re-apply the `HERMES_HOME` patch to the primary (or merge the patches)
   - If cron uses `/opt/data/home/.hermes/scripts/…` → ensure the `HERMES_HOME` guard exists there; then replace `/opt/data/scripts/…` with a symlink

3. **Synchronize logic:** The `HERMES_HOME` environment variable support is valuable for robust cron execution (cron jobs often lack a full user environment). Ensure the primary script contains this guard:
   ```python
   _home_from_env = os.environ.get('HERMES_HOME')
   if _home_from_env:
       HERMES_HOME = Path(_home_from_env) / ".hermes"
   else:
       HERMES_HOME = Path.home() / ".hermes"
   ```

4. **Replace with symlink:** After both files match:
   ```bash
   rm /opt/data/scripts/portfolio_threshold_alerts.py
   ln -s /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py /opt/data/scripts/portfolio_threshold_alerts.py
   ```

5. **Lock down write permissions:** Consider making `/opt/data/scripts/` non-writable to prevent future divergence, relying on the symlink.

## Verification

```bash
# Confirm symlink established
ls -la /opt/data/scripts/portfolio_threshold_alerts.py
# Expected output: ... -> /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py

# Confirm byte-identical
cmp /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py /opt/data/scripts/portfolio_threshold_alerts.py && echo "Identical"
```

## Session Metadata

- **Date:** 2026-05-03
- **Trigger:** Cron run produced no output; diagnostic revealed all tickers suppressed; inspection of script paths showed inconsistent file sizes
- **Tools used:** filesystem inode comparison, file size check, `diff` output
- **Action items:**
  - [ ] Confirm which script path cron executes
  - [ ] Unify the two files (merge HERMES_HOME guard into primary if not present)
  - [ ] Replace `/opt/data/scripts/` copy with symlink
  - [ ] Update skill documentation to emphasize that `/opt/data/scripts/` MUST be a symlink, not a standalone file
