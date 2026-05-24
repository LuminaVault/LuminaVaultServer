# Dependency Installation Workarounds for Hermes

**Context:** Installing community skill dependencies when Hermes venv lacks pip or has read-only site-packages.

## Bootstrap pip in Hermes Venv (Usually Fails)

```bash
# Download get-pip.py
curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py

# Run with Hermes venv Python
/opt/hermes/.venv/bin/python3 /tmp/get-pip.py
```

**Expected error (production Hermes):**
```
ERROR: Could not install packages due to an OSError:
[Errno 13] Permission denied: '/opt/hermes/.venv/lib/python3.13/site-packages/pip'
```

**Why:** Venv site-packages directory owned by root or mounted read-only.

---

## Recommended: User Site-Packages Install

```bash
# Use system Python, install to user dir (no sudo)
python3 -m pip install --user <package>

# Result: ~/.local/lib/python3.13/site-packages/<package>
```

**Verify visibility to Hermes:**
```bash
/opt/hermes/.venv/bin/python3 -c "import <package>; print('OK')"
```

**If import fails:**
```bash
# Explicitly add to PYTHONPATH in Hermes environment
export PYTHONPATH="${HOME}/.local/lib/python3.13/site-packages:${PYTHONPATH}"
```

---

## Install Specific Versions / Wheels

```bash
# Download wheel without installing
pip download --only-binary=:all: --no-deps <package> -d /tmp/wheels/

# Install wheel directly
pip install --no-index --find-links=/tmp/wheels/ <package>
```

---

## System Package Managers (Non-Python deps)

| Package | Debian/Ubuntu | macOS | Fedora/RHEL |
|---|---|---|---|
| `fluidsynth` | `sudo apt install fluidsynth` | `brew install fluidsynth` | `sudo dnf install fluidsynth` |
| `ffmpeg` | `sudo apt install ffmpeg` | `brew install ffmpeg` | `sudo dnf install ffmpeg` |
| `libsndfile` | `sudo apt install libsndfile1` | `brew install libsndfile` | `sudo dnf install libsndfile` |

---

## Poetry / uv Alternative (Isolated)

If skill uses `pyproject.toml` with `uv` or `poetry`, you can run scripts in isolated env without installing globally:

```bash
# Using uv (if available)
cd /path/to/skill/scripts
uv run analyze_instruments.py --help

# Using poetry
poetry run python script.py
```

**Benefit:** Dependencies isolated per-skill; no global install needed.

---

## Debugging Import Errors

```bash
# Check where Python looks
/opt/hermes/.venv/bin/python3 -c "import sys; print('\\n'.join(sys.path))"

# Check if package actually installed
ls ~/.local/lib/python3.13/site-packages/ | grep <package>

# Test import with verbose module search
/opt/hermes/.venv/bin/python3 -v -c "import <package>" 2>&1 | grep -i "not found"
```

---

**Related:** `community-skill-installation` skill for full workflow.
