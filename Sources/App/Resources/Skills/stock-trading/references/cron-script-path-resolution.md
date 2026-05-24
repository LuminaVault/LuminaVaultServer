# Cron Script Path Resolution

## The Issue

When a Hermes cron job runs with a script defined, the system resolves the script path as:

```python
scripts_dir = get_hermes_home() / "scripts"
path = (scripts_dir / script_name).resolve()
```

`HERMES_HOME` defaults to `~/.hermes` but in this deployment is set to `/opt/data`, making the lookup directory `/opt/data/scripts/`.

**Crucially**: the job's `workdir` setting only affects the subprocess's CWD during execution. It does **NOT** change where the script is looked up.

## Common Symptom

```
Script not found: /opt/data/scripts/stock_news_triple.py
```

Even though the script exists at:
```
/opt/data/home/.hermes/scripts/stock_news_triple.py
```

## Root Cause

- `HERMES_HOME=/opt/data` (symlinked: `/opt/data/.hermes → /opt/data/home/.hermes`)
- Cron script lookup: `HERMES_HOME/scripts/<script_name>`
- Actual script location: user's Hermes home (`/opt/data/home/.hermes/scripts/`)
- These are *different paths* despite the symlink on `.hermes` — the scripts directory itself is not symlinked.

## Solution Patterns

### Pattern 1 — Symlink the missing script (quick fix)

```bash
ln -s /opt/data/home/.hermes/scripts/stock_news_triple.py \
       /opt/data/scripts/stock_news_triple.py
```

The Hermes path validation (`validate_within_dir`) permits symlinks as long as the resolved path stays within `HERMES_HOME/scripts/`.

### Pattern 2 — Set HERMES_HOME to the user's actual Hermes home (re-alignment)

If all your scripts live in `~/.hermes/scripts/`, ensure the Hermes process uses:

```bash
export HERMES_HOME=/opt/data/home/.hermes
```

Check current value:
```bash
hermes status | grep HERMES_HOME
# or
env | grep HERMES_HOME
```

### Pattern 3 — Refactor into the expected scripts directory (canonical)

Move or copy the script into `HERMES_HOME/scripts/` so it's naturally discovered:
```bash
cp /opt/data/home/.hermes/scripts/stock_news_triple.py /opt/data/scripts/
```

## Anatomy of the Failure

1. `_run_job_script()` in `cron/scheduler.py` receives the raw script name from the job
2. It resolves: `path = (scripts_dir / raw).resolve()` where `scripts_dir = get_hermes_home() / "scripts"`
3. `validate_within_dir(path, scripts_dir)` ensures the resolved path is a child of `scripts_dir`
4. Either the path doesn't exist, or it resolves outside `scripts_dir` (blocked)

## Prevention Checklist

- [ ] For any new cron script, verify `ls $HERMES_HOME/scripts/<script_name>` succeeds
- [ ] If scripts are developed in a user's personal Hermes home (`/home/<user>/.hermes/scripts/`), ensure a copy or symlink exists in `HERMES_HOME/scripts/` for the cron user
- [ ] When setting `workdir`, remember it does NOT affect script resolution — only execution context
- [ ] In Docker deployments where `HERMES_HOME` differs from the user's home, maintain a shared `scripts/` directory or a symlink farm

## Related Code References

- Script resolution: `cron/scheduler.py::_run_job_script()` (lines ~21740)
- Path validation: `tools/path_security.py::validate_within_dir()`
- HERMES_HOME source: `hermes_constants.py::get_hermes_home()`
