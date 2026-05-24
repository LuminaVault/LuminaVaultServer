# Hermes Script Path Hygiene

Canonical scripts directory: `~/.hermes/scripts/` (or `/opt/data/home/.hermes/scripts/` on StockPlan)

Legacy/containment directory: `/opt/data/scripts/` — used by cron jobs as `workdir`, should contain **only symlinks** to the canonical location.

## Invariant

- `/opt/data/scripts/*.py` → symlinks pointing to `~/.hermes/scripts/*.py`
- No real Python files directly editable in `/opt/data/scripts/`
- Cron jobs set `workdir=/opt/data/scripts` and refer to scripts by name only (no path)

## Why this matters

- **Single source of truth:** Edit once in canonical dir; symlink reflects change everywhere.
- **Cron containment:** Hermes enforces that resolved script paths stay within `$HERMES_HOME/scripts/`. Symlink targets outside that tree fail the check.
- **Avoid FileNotFoundError:** If a script moves to a new canonical location, stale real files in `/opt/data/scripts/` will shadow the symlink and break jobs that still reference the old path.

## Diagnosis checklist

1. **Symptom:** `FileNotFoundError: '/opt/data/scripts/foo.py'` but the file exists at `~/.hermes/scripts/foo.py`
2. Check `/opt/data/scripts/foo.py`:
   - `ls -l /opt/data/scripts/foo.py` → is it a symlink (`->`) or a regular file?
   - If regular file: it's a stale duplicate. Remove it and create the symlink.
3. Verify symlink target resolves within allowed tree:
   ```bash
   python3 -c "
   from pathlib import Path
   allowed = Path('/opt/data/scripts').resolve()
   actual = Path('/opt/data/scripts/foo.py').resolve()
   try:
       actual.relative_to(allowed)
       print('OK')
   except ValueError:
       print('BLOCKED (target outside allowed):', actual)
   "
   ```
   If blocked: the symlink target lives outside `/opt/data/scripts/` (e.g., `~/.hermes/scripts/`). Either:
   - Copy the script into `/opt/data/scripts/` (safe, portable), OR
   - Restructure to place canonical scripts inside `$HERMES_HOME/scripts/` (rare)

4. Confirm cron job config:
   ```bash
   hermes cron list | grep foo
   ```
   Ensure `workdir` is `/opt/data/scripts` and `script` field is just `foo.py` (no path).

## Cleanup procedure

```bash
# 1. Remove all real Python files from /opt/data/scripts/ (keep only symlinks)
find /opt/data/scripts/ -maxdepth 1 -name '*.py' -type f -exec rm -v {} \;

# 2. Re-create symlinks for each canonical script
cd /opt/data/scripts/
for s in /opt/data/home/.hermes/scripts/*.py; do
  name=$(basename "$s")
  ln -sf "$s" "./$name"
  chmod 755 "./$name"
done

# 3. Verify symmetry
ls -l /opt/data/scripts/*.py | grep -v '^l'   # should return nothing
```

## When to copy instead of symlink

If `$HERMES_HOME` points to `/opt/data` and canonical scripts live at `~/.hermes/scripts/` (outside the allowed tree), symlinks will fail containment. In that setup, **copy** the scripts into `/opt/data/scripts/` and treat `/opt/data/scripts/` as the executable location. Edits must then be made to both copies or a deployment sync must keep them in sync.

**Preferred fix:** Reconsider the directory layout — set `$HERMES_HOME` to `/opt/data/home/.hermes` so the canonical and allowed trees align. Otherwise, accept copies and remember to update both locations on change.

## Related

- `hermes-server-monitoring` skill — cron job management, duplicate job detection
- `hermes-dev` umbrella — deployment conventions and path layout
- `hermes-remote-deploy` — provisions remote servers following the same convention
