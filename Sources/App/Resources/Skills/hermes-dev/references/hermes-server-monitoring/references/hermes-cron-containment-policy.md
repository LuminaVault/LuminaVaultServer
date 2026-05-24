# Hermes Cron Path Containment Policy

## Quick Summary

Hermes cron executes only scripts whose **resolved path** (after symlink dereferencing) falls within `$HERMES_HOME/scripts` (`/opt/data/scripts` on this host). Scripts stored elsewhere — even if accessible via symlink — are rejected with a `Blocked` error.

```
Blocked: script path resolves outside the scripts directory (/opt/data/scripts): '<script_name>'
```

## The Real Path Check

The cron agent calls `Path(script_name).resolve()` and verifies the result is a subpath of `HERMES_HOME/scripts`:

```python
from pathlib import Path
scripts_dir = Path(HERMES_HOME / 'scripts').resolve()
target_path = Path(job_script).resolve()
try:
    target_path.relative_to(scripts_dir)   # must succeed
except ValueError:
    raise BlockedError(...)
```

**Key insight:** `resolve()` follows symlinks. A symlink pointing to a file outside the allowed tree fails the check, even if the symlink itself lives inside the allowed directory.

## Diagnostic

### Check if a script is blocked

```bash
python3 -c "
from pathlib import Path
scripts_dir = Path('/opt/data/scripts').resolve()
path = Path('stock_alert_triple.py').resolve()
try:
    path.relative_to(scripts_dir)
    print('OK — within allowed directory')
except ValueError:
    print('BLOCKED — resolved path:', path)
"
```

### Inspect script symlinks

```bash
ls -l /opt/data/scripts/*.py
# Look for: script.py -> /some/other/path/script.py

readlink -f /opt/data/scripts/<script>.py
# Shows true resolved location
```

## Affected Jobs (this installation)

Jobs currently failing with Blocked errors:

| Job ID | Job Name | Script | Root Cause |
|--------|----------|--------|------------|
| `18186766daf4` | stock-alert-triple | `stock_alert_triple.py` | symlink → `/opt/data/home/.hermes/scripts/stock_alert_triple.py` |
| `a35b76eda07c` | portfolio-threshold-alerts | `portfolio_threshold_alerts.py` | symlink → `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py` |

Also historically affected: `daily-stock-news-triple`, `server-health-monitor` (when symlinked from outside).

## Fix: Copy Into Allowed Directory

Replace the symlink with an actual file copied into the allowed tree:

```bash
# Remove symlink and copy real file in place
rm /opt/data/scripts/stock_alert_triple.py
cp /opt/data/home/.hermes/scripts/stock_alert_triple.py /opt/data/scripts/
chmod 755 /opt/data/scripts/stock_alert_triple.py
```

Repeat for each affected script. After copying, re-run the diagnostic — resolved path should now be `/opt/data/scripts/<script>.py`.

## Why Not Just Use Symlinks?

The hermetic containment check prevents arbitrary code execution: a symlink could point to any file on the system, bypassing the `$HERMES_HOME/scripts` restriction entirely. By dereferencing and checking the final destination, cron ensures only files inside the designated scripts directory are run.

This also prevents privilege escalation via crafted symlinks in world-writable directories.

## Alternative: Restructure Canonical Location

If you prefer keeping a single canonical script location (avoiding copy divergence), restructure so that canonical location *itself* is within `$HERMES_HOME/scripts`:

```
/opt/data/scripts/        ← HERMES_HOME/scripts
├── stock_alert_triple.py   ← real file (canonical)
└── stock_alert_slack.py    ← real file (canonical)
```

Edit scripts directly in `/opt/data/scripts/` and abandon `~/.hermes/scripts/` as script storage. This symmetry simplifies both cron and the security check.

**When this is impractical:** If you maintain a large personal script archive in `~/.hermes/scripts/` that you don't want to move, copying a curated subset into `/opt/data/scripts/` is the pragmatic solution.

## Verification

After applying the fix:

```bash
# 1. Confirm resolved path is contained
python3 -c "
from pathlib import Path
p = Path('/opt/data/scripts/stock_alert_triple.py').resolve()
print('Resolved:', p)
print('Inside allowed dir:', str(p).startswith('/opt/data/scripts/'))
"

# 2. Ensure executable bit
ls -l /opt/data/scripts/stock_alert_triple.py
# → -rwxr-xr-x ... (755)

# 3. Manual dry-run
python3 /opt/data/scripts/stock_alert_triple.py
# Should exit 0 or 1; no Blocked error

# 4. Trigger one-off cron run (if `hermes` CLI available):
hermes cron run 18186766daf4
```

## Duplicate Detection

After fixing containment issues, check for other symlinks in `/opt/data/scripts/` that may be affected:

```bash
# List all symlinks
find /opt/data/scripts/ -name '*.py' -type l -exec ls -l {} \;

# For each symlink, check realpath containment
python3 -c "
from pathlib import Path
scripts_dir = Path('/opt/data/scripts').resolve()
import os, glob
for link in glob.glob('/opt/data/scripts/*.py'):
    if os.path.islink(link):
        target = Path(link).resolve()
        try:
            target.relative_to(scripts_dir)
        except ValueError:
            print(f'BLOCKED SYMLINK: {os.path.basename(link)} -> {target}')
"
```

## See Also

- SKILL: `hermes-server-monitoring` — full cron job troubleshooting guide
- Reference: `hermes-scripts-symlink-convention.md` — historical symlink pattern and its limitations
